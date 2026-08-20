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
    private var onMemory: (([MemoryRecord]) -> Void)?
    private var onCheckpoint: ((RunCheckpoint?, Bool) -> Void)?
    private var onFinish: ((RunSession) -> Void)?
    private var didFinish = false

    var isActive: Bool {
        session.phase == .running || session.phase == .awaitingApproval
    }

    func start(
        workspace: ProjectWorkspace,
        workingDirectory: URL,
        runID: UUID = UUID(),
        onMemory: @escaping ([MemoryRecord]) -> Void,
        onCheckpoint: @escaping (RunCheckpoint?, Bool) -> Void,
        onFinish: @escaping (RunSession) -> Void
    ) {
        guard !isActive else { return }
        if let message = WorkspaceRules.validationMessage(for: workspace) {
            failBeforeStart(message, projectID: workspace.id, runID: runID, onFinish: onFinish)
            return
        }
        let executable = workspace.cliSettings.executablePath
        if executable.hasPrefix("/"), !FileManager.default.isExecutableFile(atPath: executable) {
            failBeforeStart("找不到可执行的 Codex CLI：\(executable)", projectID: workspace.id, runID: runID, onFinish: onFinish)
            return
        }

        runtimeWorkspace = AutomaticMemoryService.synchronizeMainline(in: workspace)
        self.workingDirectory = workingDirectory
        self.onMemory = onMemory
        self.onCheckpoint = onCheckpoint
        self.onFinish = onFinish
        approvedGateIDs = []
        reviewRetryCounts = [:]
        pendingApprovalStepIndex = nil
        currentContextPreview = ""
        didFinish = false
        session = RunSession(
            id: runID,
            phase: .running,
            startedAt: Date(),
            completedAt: nil,
            currentStepIndex: 0,
            executions: [],
            events: [
                RunEvent(message: "通过本机 Codex CLI 启动流程；复用 CLI 登录状态，每一步按蓝图选择 read-only 或 workspace-write。"),
                RunEvent(message: "项目：\(workspace.projectName)，共 \(workspace.steps.count) 个顺序步骤。", kind: "project")
            ],
            errorMessage: nil,
            projectID: workspace.id
        )
        publishCheckpoint(nextStepIndex: 0, immediate: true)
        launchLoop(startingAt: 0)
    }

    func resume(
        workspace: ProjectWorkspace,
        workingDirectory: URL,
        checkpoint: RunCheckpoint,
        onMemory: @escaping ([MemoryRecord]) -> Void,
        onCheckpoint: @escaping (RunCheckpoint?, Bool) -> Void,
        onFinish: @escaping (RunSession) -> Void
    ) {
        guard !isActive else { return }
        guard checkpoint.projectID == workspace.id,
              checkpoint.session.projectID == workspace.id else {
            failBeforeStart("运行检查点不属于当前项目，无法继续。", projectID: workspace.id, runID: checkpoint.session.id, onFinish: onFinish)
            onCheckpoint(nil, true)
            return
        }
        if let message = WorkspaceRules.validationMessage(for: workspace) {
            failBeforeStart(message, projectID: workspace.id, runID: checkpoint.session.id, onFinish: onFinish)
            return
        }
        let executable = workspace.cliSettings.executablePath
        if executable.hasPrefix("/"), !FileManager.default.isExecutableFile(atPath: executable) {
            failBeforeStart("找不到可执行的 Codex CLI：\(executable)", projectID: workspace.id, runID: checkpoint.session.id, onFinish: onFinish)
            return
        }

        runtimeWorkspace = AutomaticMemoryService.synchronizeMainline(in: workspace)
        self.workingDirectory = workingDirectory
        self.onMemory = onMemory
        self.onCheckpoint = onCheckpoint
        self.onFinish = onFinish
        let validStepIDs = Set(workspace.steps.map(\.id))
        approvedGateIDs = Set(checkpoint.approvedGateIDs.filter(validStepIDs.contains))
        reviewRetryCounts = [:]
        for retry in checkpoint.reviewRetryCounts where validStepIDs.contains(retry.reviewerStepID) {
            reviewRetryCounts[retry.reviewerStepID] = min(max(retry.retryCount, 0), 5)
        }
        pendingApprovalStepIndex = nil
        didFinish = false

        session = checkpoint.session
        let now = Date()
        for index in session.executions.indices where session.executions[index].status == .running {
            session.executions[index].status = .interrupted
            session.executions[index].completedAt = now
            session.executions[index].errorMessage = "上次运行异常中断；本次会保留部分产物并重新执行该步骤。"
        }
        let resumeIndex = min(max(checkpoint.nextStepIndex, 0), workspace.steps.count)
        session.phase = .running
        session.completedAt = nil
        session.errorMessage = nil
        session.currentStepIndex = resumeIndex < workspace.steps.count ? resumeIndex : nil
        currentContextPreview = session.executions.last?.contextPreview ?? ""
        session.events.append(
            RunEvent(
                message: "已从异常退出检查点恢复；已完成步骤与审核回环状态保持不变，中断步骤将基于部分产物重新执行。",
                kind: "recovery"
            )
        )
        publishCheckpoint(nextStepIndex: resumeIndex, immediate: true)
        launchLoop(startingAt: resumeIndex)
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
        publishCheckpoint(nextStepIndex: index, immediate: true)
        launchLoop(startingAt: index)
    }

    func cancel() {
        guard isActive else { return }
        runTask?.cancel()
        runTask = nil
        pendingApprovalStepIndex = nil
        for index in session.executions.indices where session.executions[index].status == .running {
            session.executions[index].status = .cancelled
            session.executions[index].completedAt = Date()
            session.executions[index].errorMessage = "运行已由用户取消。"
        }
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
        onCheckpoint = nil
    }

    private func failBeforeStart(
        _ message: String,
        projectID: UUID,
        runID: UUID,
        onFinish: @escaping (RunSession) -> Void
    ) {
        session = RunSession(
            id: runID,
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
                    publishCheckpoint(nextStepIndex: index, immediate: true)
                    return
                }

                session.phase = .running
                let result = try await execute(step: step, at: index, workspace: workspace)
                let role = workspace.agents.first(where: { $0.id == step.agentID })?.role
                let isReviewStep = role == .reviewer || step.reviewReturnStepID != nil

                if isReviewStep {
                    guard let verdict = ReviewVerdictParser.parse(result.output) else {
                        session.events.append(
                            RunEvent(message: "审核步骤没有返回 AIGO_VERDICT，不能把未知结果当作通过。", kind: "error")
                        )
                        throw OrchestrationError.missingReviewVerdict(step.title)
                    }
                    if verdict == .fail {
                        guard let returnID = step.reviewReturnStepID,
                              let returnIndex = workspace.steps.firstIndex(where: { $0.id == returnID }),
                              returnIndex < index else {
                            throw OrchestrationError.reviewRejectedWithoutReturn(step.title)
                        }
                        let retryCount = reviewRetryCounts[step.id, default: 0]
                        if retryCount < step.maxReviewRetries {
                            let nextAttempt = retryCount + 1
                            reviewRetryCounts[step.id] = nextAttempt
                            session.events.append(
                                RunEvent(
                                    message: "审核判定 FAIL；自动回到第 \(returnIndex + 1) 步“\(workspace.steps[returnIndex].title)”返工（第 \(nextAttempt)/\(step.maxReviewRetries) 次回环）。",
                                    kind: "retry"
                                )
                            )
                            index = returnIndex
                            publishCheckpoint(nextStepIndex: returnIndex, immediate: true)
                            continue
                        }
                        session.events.append(
                            RunEvent(message: "审核仍为 FAIL；已达到 \(step.maxReviewRetries) 次回环上限，流程停止。", kind: "error")
                        )
                        throw OrchestrationError.reviewRejected(step.maxReviewRetries)
                    }
                    session.events.append(RunEvent(message: "第 \(index + 1) 步审核判定 PASS。", kind: "success"))
                }

                integrateMemories(forExecutionAt: result.executionIndex)

                index += 1
                publishCheckpoint(nextStepIndex: index, immediate: true)
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
    ) async throws -> (output: String, executionIndex: Int) {
        guard let agent = workspace.agents.first(where: { $0.id == step.agentID }) else {
            throw OrchestrationError.invalidConfiguration("第 \(index + 1) 步没有可用智能体。")
        }
        guard let profile = workspace.profiles.first(where: { $0.id == agent.profileID }) else {
            throw OrchestrationError.invalidConfiguration("智能体“\(agent.name)”没有可用 Codex CLI 配置。")
        }
        guard let workingDirectory else {
            throw OrchestrationError.invalidConfiguration("项目工作目录尚未建立。")
        }

        let prior = session.executions.filter {
            $0.status == .completed || ($0.status == .interrupted && !$0.output.isEmpty)
        }
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
            reasoningEffort: profile.reasoningEffort.rawValue,
            executionAccess: step.executionAccess
        )
        session.executions.append(execution)
        let executionIndex = session.executions.count - 1
        let modelLabel = profile.modelID.isEmpty ? "CLI 当前默认模型" : profile.modelID
        session.events.append(
            RunEvent(message: "\(agent.name) 开始第 \(index + 1) 步“\(step.title)”（\(modelLabel) / \(profile.reasoningEffort.title) / \(step.executionAccess.rawValue)）。")
        )
        publishCheckpoint(nextStepIndex: index, immediate: true)

        do {
            var receivedMessage = false
            for try await event in CodexCLIService.stream(
                executablePath: workspace.cliSettings.executablePath,
                workingDirectory: workingDirectory,
                modelID: profile.modelID,
                reasoningEffort: profile.reasoningEffort,
                executionAccess: step.executionAccess,
                prompt: input
            ) {
                try Task.checkCancellation()
                switch event {
                case .threadStarted(let threadID):
                    session.executions[executionIndex].cliThreadID = threadID
                    session.events.append(RunEvent(message: "Codex CLI 线程已启动：\(threadID.prefix(8))。", kind: "cli"))
                    publishCheckpoint(nextStepIndex: index, immediate: false)
                case .agentMessage(let message):
                    if receivedMessage, !session.executions[executionIndex].output.isEmpty {
                        session.executions[executionIndex].output += "\n\n"
                    }
                    receivedMessage = true
                    session.executions[executionIndex].output += message
                    publishCheckpoint(nextStepIndex: index, immediate: false)
                case .activity(let activity):
                    session.executions[executionIndex].activityLog?.append(activity)
                    session.events.append(RunEvent(message: activity, kind: "activity"))
                    publishCheckpoint(nextStepIndex: index, immediate: false)
                case .completed(let usage):
                    session.executions[executionIndex].inputTokens = usage.inputTokens
                    session.executions[executionIndex].outputTokens = usage.outputTokens
                    publishCheckpoint(nextStepIndex: index, immediate: false)
                case .failed(let message):
                    throw OrchestrationError.cli(message)
                }
            }

            guard receivedMessage, !session.executions[executionIndex].output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CodexCLIError.noAgentMessage
            }
            session.executions[executionIndex].status = .completed
            session.executions[executionIndex].completedAt = Date()
            return (session.executions[executionIndex].output, executionIndex)
        } catch {
            session.executions[executionIndex].status = error is CancellationError ? .cancelled : .failed
            session.executions[executionIndex].errorMessage = error.localizedDescription
            session.executions[executionIndex].completedAt = Date()
            throw error
        }
    }

    private func integrateMemories(forExecutionAt executionIndex: Int) {
        guard session.executions.indices.contains(executionIndex) else { return }
        let execution = session.executions[executionIndex]
        let memories = AutomaticMemoryService.stepMemories(from: execution, runID: session.id)
        guard let current = runtimeWorkspace else { return }
        let result = AutomaticMemoryService.upserting(memories, into: current)
        runtimeWorkspace = result.project
        let integratedRecords = result.records
        onMemory?(integratedRecords)
        session.events.append(
            RunEvent(
                message: "第 \(execution.stepNumber) 步已完成，已提取或更新 \(integratedRecords.count) 条细粒度共享知识。",
                kind: "success"
            )
        )
    }

    private func publishCheckpoint(nextStepIndex: Int, immediate: Bool) {
        guard let projectID = session.projectID,
              session.phase == .running || session.phase == .awaitingApproval else { return }
        let retries = reviewRetryCounts
            .map { ReviewRetryCheckpoint(reviewerStepID: $0.key, retryCount: $0.value) }
            .sorted { $0.reviewerStepID.uuidString < $1.reviewerStepID.uuidString }
        let checkpoint = RunCheckpoint(
            projectID: projectID,
            session: session,
            nextStepIndex: nextStepIndex,
            approvedGateIDs: approvedGateIDs.sorted { $0.uuidString < $1.uuidString },
            reviewRetryCounts: retries
        )
        onCheckpoint?(checkpoint, immediate)
    }

    private func finishOnce() {
        guard !didFinish else { return }
        didFinish = true
        let handler = onFinish
        onFinish = nil
        onMemory = nil
        onCheckpoint = nil
        handler?(session)
    }
}

private enum OrchestrationError: LocalizedError {
    case reviewRejected(Int)
    case reviewRejectedWithoutReturn(String)
    case missingReviewVerdict(String)
    case invalidConfiguration(String)
    case cli(String)

    var errorDescription: String? {
        switch self {
        case .reviewRejected(let retries):
            return "审核在自动回退 \(retries) 次后仍未通过，本次流程已停止。"
        case .reviewRejectedWithoutReturn(let title):
            return "审核步骤“\(title)”判定 FAIL，但没有配置有效的更早回退步骤，本次流程已停止。"
        case .missingReviewVerdict(let title):
            return "审核步骤“\(title)”缺少 AIGO_VERDICT: PASS/FAIL，无法安全继续。"
        case .invalidConfiguration(let message), .cli(let message):
            return message
        }
    }
}
