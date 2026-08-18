import Foundation
import SwiftUI

@MainActor
final class OrchestrationEngine: ObservableObject {
    @Published private(set) var session: RunSession = .idle
    @Published private(set) var pendingApprovalStepIndex: Int?
    @Published private(set) var currentContextPreview = ""

    private var runTask: Task<Void, Never>?
    private var runtimeWorkspace: ProjectWorkspace?
    private var workingDirectory: URL?
    private var approvedGateIDs = Set<UUID>()
    private var reviewRetryCounts: [UUID: Int] = [:]
    private var onMemory: ((MemoryRecord) -> Void)?
    private var onFinish: ((RunSession) -> Void)?
    private var didFinish = false

    var isActive: Bool {
        session.phase == .running || session.phase == .awaitingApproval
    }

    func start(
        workspace: ProjectWorkspace,
        workingDirectory: URL,
        onMemory: @escaping (MemoryRecord) -> Void,
        onFinish: @escaping (RunSession) -> Void
    ) {
        guard !isActive else { return }
        if let message = WorkspaceRules.validationMessage(for: workspace) {
            failBeforeStart(message, projectID: workspace.id, onFinish: onFinish)
            return
        }
        let executable = workspace.cliSettings.executablePath
        if executable.hasPrefix("/"), !FileManager.default.isExecutableFile(atPath: executable) {
            failBeforeStart("找不到可执行的 Codex CLI：\(executable)", projectID: workspace.id, onFinish: onFinish)
            return
        }

        runtimeWorkspace = AutomaticMemoryService.synchronizeMainline(in: workspace)
        self.workingDirectory = workingDirectory
        self.onMemory = onMemory
        self.onFinish = onFinish
        approvedGateIDs = []
        reviewRetryCounts = [:]
        pendingApprovalStepIndex = nil
        currentContextPreview = ""
        didFinish = false
        session = RunSession(
            id: UUID(),
            phase: .running,
            startedAt: Date(),
            completedAt: nil,
            currentStepIndex: 0,
            executions: [],
            events: [
                RunEvent(message: "通过本机 Codex CLI 启动流程；复用 CLI 登录状态，工作目录采用 read-only 沙箱。"),
                RunEvent(message: "项目：\(workspace.projectName)，共 \(workspace.steps.count) 个顺序步骤。", kind: "project")
            ],
            errorMessage: nil,
            projectID: workspace.id
        )
        launchLoop(startingAt: 0)
    }

    func approveAndContinue() {
        guard session.phase == .awaitingApproval,
              let index = pendingApprovalStepIndex,
              let workspace = runtimeWorkspace,
              workspace.steps.indices.contains(index) else { return }
        let step = workspace.steps[index]
        approvedGateIDs.insert(step.id)
        pendingApprovalStepIndex = nil
        session.phase = .running
        session.events.append(RunEvent(message: "用户批准第 \(index + 1) 步“\(step.title)”。", kind: "approval"))
        launchLoop(startingAt: index)
    }

    func cancel() {
        guard isActive else { return }
        runTask?.cancel()
        runTask = nil
        pendingApprovalStepIndex = nil
        session.phase = .cancelled
        session.completedAt = Date()
        session.events.append(RunEvent(message: "运行已由用户取消，并终止当前 Codex CLI 子进程。", kind: "warning"))
        finishOnce()
    }

    func resetMonitor() {
        guard !isActive else { return }
        session = .idle
        pendingApprovalStepIndex = nil
        currentContextPreview = ""
        runtimeWorkspace = nil
        workingDirectory = nil
    }

    private func failBeforeStart(
        _ message: String,
        projectID: UUID,
        onFinish: @escaping (RunSession) -> Void
    ) {
        session = RunSession(
            id: UUID(),
            phase: .failed,
            startedAt: Date(),
            completedAt: Date(),
            currentStepIndex: nil,
            executions: [],
            events: [RunEvent(message: message, kind: "error")],
            errorMessage: message,
            projectID: projectID
        )
        onFinish(session)
    }

    private func launchLoop(startingAt index: Int) {
        runTask?.cancel()
        runTask = Task { [weak self] in
            await self?.executeLoop(startingAt: index)
        }
    }

    private func executeLoop(startingAt initialIndex: Int) async {
        var index = initialIndex

        do {
            while let workspace = runtimeWorkspace, index < workspace.steps.count {
                try Task.checkCancellation()
                let step = workspace.steps[index]
                session.currentStepIndex = index

                if step.requiresApproval && !approvedGateIDs.contains(step.id) {
                    pendingApprovalStepIndex = index
                    session.phase = .awaitingApproval
                    session.events.append(
                        RunEvent(message: "第 \(index + 1) 步“\(step.title)”需要人工批准后才能调用 Codex CLI。", kind: "approval")
                    )
                    return
                }

                session.phase = .running
                let output = try await execute(step: step, at: index, workspace: workspace)

                if output.uppercased().contains("VERDICT: FAIL"),
                   let returnID = step.reviewReturnStepID,
                   let returnIndex = workspace.steps.firstIndex(where: { $0.id == returnID }) {
                    let retryCount = reviewRetryCounts[returnID, default: 0]
                    if retryCount < 1 {
                        reviewRetryCounts[returnID] = retryCount + 1
                        session.events.append(
                            RunEvent(
                                message: "审核未通过，自动回到第 \(returnIndex + 1) 步“\(workspace.steps[returnIndex].title)”重做一次。",
                                kind: "retry"
                            )
                        )
                        index = returnIndex
                        continue
                    }
                    session.events.append(
                        RunEvent(message: "审核仍未通过；已达到一次自动回退上限，流程停止。", kind: "error")
                    )
                    throw OrchestrationError.reviewRejected
                }

                index += 1
            }

            session.phase = .completed
            session.currentStepIndex = nil
            session.completedAt = Date()
            session.events.append(RunEvent(message: "全部流程步骤执行完成。", kind: "success"))
            runTask = nil
            finishOnce()
        } catch is CancellationError {
            if session.phase != .cancelled {
                session.phase = .cancelled
                session.completedAt = Date()
                session.events.append(RunEvent(message: "运行任务已取消。", kind: "warning"))
                finishOnce()
            }
        } catch {
            session.phase = .failed
            session.completedAt = Date()
            session.errorMessage = error.localizedDescription
            session.events.append(RunEvent(message: error.localizedDescription, kind: "error"))
            runTask = nil
            finishOnce()
        }
    }

    private func execute(
        step: WorkflowStep,
        at index: Int,
        workspace: ProjectWorkspace
    ) async throws -> String {
        guard let agent = workspace.agents.first(where: { $0.id == step.agentID }) else {
            throw OrchestrationError.invalidConfiguration("第 \(index + 1) 步没有可用智能体。")
        }
        guard let profile = workspace.profiles.first(where: { $0.id == agent.profileID }) else {
            throw OrchestrationError.invalidConfiguration("智能体“\(agent.name)”没有可用 Codex CLI 配置。")
        }
        guard let workingDirectory else {
            throw OrchestrationError.invalidConfiguration("项目工作目录尚未建立。")
        }

        let prior = session.executions.filter { $0.status == .completed }
        let input = PromptComposer.input(
            project: workspace,
            agent: agent,
            step: step,
            stepNumber: index + 1,
            priorExecutions: prior
        )
        currentContextPreview = input
        let attempt = session.executions.filter { $0.stepID == step.id }.count + 1
        let execution = StepExecution(
            stepID: step.id,
            stepNumber: index + 1,
            stepTitle: step.title,
            agentName: agent.name,
            attempt: attempt,
            contextPreview: input,
            modelID: profile.modelID.isEmpty ? nil : profile.modelID,
            reasoningEffort: profile.reasoningEffort.rawValue
        )
        session.executions.append(execution)
        let executionIndex = session.executions.count - 1
        let modelLabel = profile.modelID.isEmpty ? "CLI 当前默认模型" : profile.modelID
        session.events.append(
            RunEvent(message: "\(agent.name) 开始第 \(index + 1) 步“\(step.title)”（\(modelLabel) / \(profile.reasoningEffort.title)）。")
        )

        do {
            var receivedMessage = false
            for try await event in CodexCLIService.stream(
                executablePath: workspace.cliSettings.executablePath,
                workingDirectory: workingDirectory,
                modelID: profile.modelID,
                reasoningEffort: profile.reasoningEffort,
                prompt: input
            ) {
                try Task.checkCancellation()
                switch event {
                case .threadStarted(let threadID):
                    session.executions[executionIndex].cliThreadID = threadID
                    session.events.append(RunEvent(message: "Codex CLI 线程已启动：\(threadID.prefix(8))。", kind: "cli"))
                case .agentMessage(let message):
                    if receivedMessage, !session.executions[executionIndex].output.isEmpty {
                        session.executions[executionIndex].output += "\n\n"
                    }
                    receivedMessage = true
                    session.executions[executionIndex].output += message
                case .activity(let activity):
                    session.executions[executionIndex].activityLog?.append(activity)
                    session.events.append(RunEvent(message: activity, kind: "activity"))
                case .completed(let usage):
                    session.executions[executionIndex].inputTokens = usage.inputTokens
                    session.executions[executionIndex].outputTokens = usage.outputTokens
                case .failed(let message):
                    throw OrchestrationError.cli(message)
                }
            }

            guard receivedMessage, !session.executions[executionIndex].output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CodexCLIError.noAgentMessage
            }
            session.executions[executionIndex].status = .completed
            session.executions[executionIndex].completedAt = Date()

            let memories = AutomaticMemoryService.stepMemories(from: session.executions[executionIndex], runID: session.id)
            var integratedCount = 0
            for memory in memories {
                guard let current = runtimeWorkspace else { break }
                let result = AutomaticMemoryService.upserting(memory, into: current)
                runtimeWorkspace = result.project
                onMemory?(result.record)
                integratedCount += 1
            }
            session.events.append(
                RunEvent(
                    message: "第 \(index + 1) 步已完成，已提取或更新 \(integratedCount) 条细粒度共享知识。",
                    kind: "success"
                )
            )
            return session.executions[executionIndex].output
        } catch {
            session.executions[executionIndex].status = error is CancellationError ? .cancelled : .failed
            session.executions[executionIndex].errorMessage = error.localizedDescription
            session.executions[executionIndex].completedAt = Date()
            throw error
        }
    }

    private func finishOnce() {
        guard !didFinish else { return }
        didFinish = true
        if session.phase != .idle {
            let summary = AutomaticMemoryService.runSummary(from: session)
            onMemory?(summary)
        }
        let handler = onFinish
        onFinish = nil
        onMemory = nil
        handler?(session)
    }
}

private enum OrchestrationError: LocalizedError {
    case reviewRejected
    case invalidConfiguration(String)
    case cli(String)

    var errorDescription: String? {
        switch self {
        case .reviewRejected:
            return "审核在自动回退重做后仍未通过，本次流程已停止。"
        case .invalidConfiguration(let message), .cli(let message):
            return message
        }
    }
}
