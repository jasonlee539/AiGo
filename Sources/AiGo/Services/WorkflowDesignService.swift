import Foundation

struct WorkflowProposal: Identifiable, Hashable {
    var id = UUID()
    var summary: String
    var steps: [WorkflowStep]
    var warnings: [String]
    var designerAgentID: UUID
    var generatedAt = Date()
    var rawOutput: String
}

enum WorkflowDesignService {
    static let maximumGeneratedSteps = 24

    static func generate(
        project: ProjectWorkspace,
        designerAgentID: UUID,
        request: String,
        workingDirectory: URL
    ) async throws -> WorkflowProposal {
        guard let designer = project.agents.first(where: { $0.id == designerAgentID }) else {
            throw WorkflowDesignError.designerMissing
        }
        guard let profile = project.profiles.first(where: { $0.id == designer.profileID }) else {
            throw WorkflowDesignError.profileMissing
        }

        let completion = try await CodexCLIService.complete(
            executablePath: project.cliSettings.executablePath,
            workingDirectory: workingDirectory,
            modelID: profile.modelID,
            reasoningEffort: profile.reasoningEffort,
            executionAccess: .readOnly,
            prompt: prompt(project: project, designer: designer, request: request)
        )
        return try parse(
            completion.output,
            project: project,
            designerAgentID: designerAgentID
        )
    }

    static func prompt(project: ProjectWorkspace, designer: AgentSeat, request: String) -> String {
        let roles = project.agents.map { agent in
            "- agent_id=\(agent.id.uuidString)｜名称=\(agent.name)｜角色=\(agent.roleTitle)｜职责=\(bounded(agent.instruction, limit: 500))"
        }.joined(separator: "\n")
        let existing = project.steps.enumerated().map { index, step in
            let agent = project.agents.first(where: { $0.id == step.agentID })?.name ?? "未分配"
            return "\(index + 1). \(step.title) → \(agent)：\(bounded(step.instruction, limit: 300))"
        }.joined(separator: "\n")
        let focus = request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? project.projectBrief : request

        return """
        你是 AiGo 项目“\(project.projectName)”的流程设计师“\(designer.name)”。你只负责设计可执行流程草案，不执行这些任务，也不修改文件。

        # 项目目标与约束
        \(project.projectBrief)

        # 用户本次分配要求
        \(focus)

        # 只能使用以下现有智能体
        \(roles)

        # 当前流程（可重构）
        \(existing.isEmpty ? "（当前为空）" : existing)

        # 设计规则
        - 生成 1 到 \(maximumGeneratedSteps) 个有明确先后关系的步骤。
        - 默认优先设计 3 到 6 个足以完成目标的步骤；只有任务确实需要时才超过 6 步。合并同一角色连续、可一次完成的工作，禁止仅用于转述上游内容的微步骤。
        - 每一步必须同时填写非空 title 和 instruction。instruction 必须写清输入、具体动作、真实交付物、完成判据和失败处理，不能只写角色名称或笼统短语。
        - agent_id 必须逐字使用上方 UUID，禁止发明新角色。
        - input_mode 只能是 previous 或 accumulated。
        - 默认执行权限是 workspace-write。纯分析或审核步骤可以显式使用 read-only；审核员必须 read-only。
        - 代码步骤必须要求检查并修改当前目录中的真实代码、运行测试或构建、汇报变更文件；禁止只产出伪代码。
        - 审核步骤必须要求单独输出 AIGO_VERDICT: PASS 或 AIGO_VERDICT: FAIL。
        - 审核可用 review_return_to 指向更早步骤的 key，形成“返工 → 重新审核”回环；禁止指向自身或未来步骤。没有回环时填 null。
        - max_review_retries 取 1 到 5。回环必须有界，不得设计无限循环。

        # 唯一允许的输出
        只输出一个合法 JSON 对象，不要 Markdown 围栏、解释或额外文字：
        {
          "summary": "流程设计摘要",
          "warnings": ["需要用户注意的边界"],
          "steps": [
            {
              "key": "step-1",
              "title": "完整步骤名称",
              "instruction": "完整任务指令",
              "agent_id": "上方某个 UUID",
              "input_mode": "accumulated",
              "execution_access": "workspace-write",
              "requires_approval": false,
              "review_return_to": null,
              "max_review_retries": 1
            }
          ]
        }
        """
    }

    static func parse(
        _ output: String,
        project: ProjectWorkspace,
        designerAgentID: UUID
    ) throws -> WorkflowProposal {
        guard let json = firstJSONObject(in: output), let data = json.data(using: .utf8) else {
            throw WorkflowDesignError.invalidJSON
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let payload: Payload
        do {
            payload = try decoder.decode(Payload.self, from: data)
        } catch {
            throw WorkflowDesignError.decode(error.localizedDescription)
        }
        guard !payload.steps.isEmpty else { throw WorkflowDesignError.emptyWorkflow }
        guard payload.steps.count <= maximumGeneratedSteps else {
            throw WorkflowDesignError.tooManySteps(payload.steps.count)
        }

        let agents = Dictionary(uniqueKeysWithValues: project.agents.map { ($0.id, $0) })
        var keys = Set<String>()
        var stepIDs: [String: UUID] = [:]
        for (index, raw) in payload.steps.enumerated() {
            let key = normalizedKey(raw.key)
            guard !key.isEmpty else { throw WorkflowDesignError.missingField(index + 1, "key") }
            guard keys.insert(key).inserted else { throw WorkflowDesignError.duplicateKey(raw.key) }
            stepIDs[key] = UUID()
        }

        var steps: [WorkflowStep] = []
        for (index, raw) in payload.steps.enumerated() {
            let title = raw.title.trimmingCharacters(in: .whitespacesAndNewlines)
            var instruction = raw.instruction.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { throw WorkflowDesignError.missingField(index + 1, "title") }
            guard !instruction.isEmpty else { throw WorkflowDesignError.missingField(index + 1, "instruction") }
            instruction = bounded(instruction, limit: 4_000)
            guard let agentID = UUID(uuidString: raw.agentId), let agent = agents[agentID] else {
                throw WorkflowDesignError.invalidAgent(index + 1, raw.agentId)
            }
            let requestsLoop = raw.reviewReturnTo?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false

            let requestedAccess = raw.executionAccess.flatMap(StepExecutionAccess.init(rawValue:)) ?? .workspaceWrite
            let access: StepExecutionAccess
            if agent.role == .reviewer {
                access = .readOnly
            } else if agent.role == .coder {
                access = .workspaceWrite
            } else {
                access = requestedAccess
            }

            if access == .workspaceWrite {
                instruction += "\n\n执行要求：必须检查并修改当前项目目录中的真实文件，运行相关测试或构建并修复错误；最终列出变更文件和验证结果，不得只返回伪代码或代码片段。"
            }
            if agent.role == .reviewer || requestsLoop {
                instruction += "\n\n机器判定：必须单独输出且只输出一个结论行 AIGO_VERDICT: PASS 或 AIGO_VERDICT: FAIL；失败时给出可供回退步骤直接执行的修改清单。"
            }

            let currentKey = normalizedKey(raw.key)
            var returnID: UUID?
            if let rawReturn = raw.reviewReturnTo?.trimmingCharacters(in: .whitespacesAndNewlines), !rawReturn.isEmpty {
                let returnKey = normalizedKey(rawReturn)
                guard let returnIndex = payload.steps.firstIndex(where: { normalizedKey($0.key) == returnKey }),
                      returnIndex < index,
                      let resolved = stepIDs[returnKey] else {
                    throw WorkflowDesignError.invalidLoop(currentKey, rawReturn)
                }
                returnID = resolved
            }

            let step = WorkflowStep(
                id: stepIDs[currentKey] ?? UUID(),
                title: bounded(title, limit: 120),
                instruction: bounded(instruction, limit: 5_000),
                agentID: agentID,
                inputMode: StepInputMode(rawValue: raw.inputMode ?? "") ?? .accumulated,
                executionAccess: access,
                requiresApproval: raw.requiresApproval ?? false,
                reviewReturnStepID: returnID,
                maxReviewRetries: raw.maxReviewRetries ?? 1
            )
            steps.append(step)
        }

        return WorkflowProposal(
            summary: payload.summary?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "设计师已生成 \(steps.count) 步流程草案。",
            steps: steps,
            warnings: (payload.warnings ?? [])
                .map { bounded($0.trimmingCharacters(in: .whitespacesAndNewlines), limit: 500) }
                .filter { !$0.isEmpty },
            designerAgentID: designerAgentID,
            rawOutput: output
        )
    }

    private struct Payload: Decodable {
        var summary: String?
        var warnings: [String]?
        var steps: [RawStep]
    }

    private struct RawStep: Decodable {
        var key: String
        var title: String
        var instruction: String
        var agentId: String
        var inputMode: String?
        var executionAccess: String?
        var requiresApproval: Bool?
        var reviewReturnTo: String?
        var maxReviewRetries: Int?
    }

    private static func firstJSONObject(in text: String) -> String? {
        var start: String.Index?
        var depth = 0
        var inString = false
        var escaped = false

        for index in text.indices {
            let character = text[index]
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
                continue
            }
            if character == "\"" {
                inString = true
            } else if character == "{" {
                if depth == 0 { start = index }
                depth += 1
            } else if character == "}", depth > 0 {
                depth -= 1
                if depth == 0, let start {
                    return String(text[start...index])
                }
            }
        }
        return nil
    }

    private static func normalizedKey(_ value: String) -> String {
        value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func bounded(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        return String(value.prefix(max(0, limit - 16))) + "…（已限长）"
    }
}

private enum WorkflowDesignError: LocalizedError {
    case designerMissing
    case profileMissing
    case invalidJSON
    case decode(String)
    case emptyWorkflow
    case tooManySteps(Int)
    case missingField(Int, String)
    case duplicateKey(String)
    case invalidAgent(Int, String)
    case invalidLoop(String, String)

    var errorDescription: String? {
        switch self {
        case .designerMissing: return "找不到选定的流程设计师。"
        case .profileMissing: return "流程设计师没有可用的 Codex CLI 配置。"
        case .invalidJSON: return "设计师没有返回可解析的 JSON 流程草案。请重试或补充要求。"
        case .decode(let detail): return "流程草案 JSON 字段不完整：\(detail)"
        case .emptyWorkflow: return "设计师返回了空流程。"
        case .tooManySteps(let count): return "设计师返回 \(count) 步，超过单次 \(WorkflowDesignService.maximumGeneratedSteps) 步上限。"
        case .missingField(let index, let field): return "草案第 \(index) 步缺少 \(field)。"
        case .duplicateKey(let key): return "草案存在重复步骤 key：\(key)"
        case .invalidAgent(let index, let value): return "草案第 \(index) 步引用了不存在的智能体：\(value)"
        case .invalidLoop(let step, let target): return "步骤 \(step) 的回环目标 \(target) 不是更早步骤。"
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
