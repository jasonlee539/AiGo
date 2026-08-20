import Foundation

enum PromptComposer {
    private static let upstreamCharacterBudget = 8_000
    private static let latestOutputBudget = 4_500
    private static let earlierDigestBudget = 450

    static func input(
        project: ProjectWorkspace,
        agent: AgentSeat,
        step: WorkflowStep,
        stepNumber: Int,
        priorExecutions: [StepExecution]
    ) -> String {
        let memorySelection = AutomaticMemoryService.selectMemories(
            from: project,
            agent: agent,
            step: step
        )
        let memoryText = memorySelection.records.isEmpty
            ? "（当前没有与本任务匹配的有效知识）"
            : memorySelection.records.map {
                "[\($0.kind.title)] \($0.title)｜来源：\($0.source)｜修订：\($0.revision)\n\($0.content)"
            }.joined(separator: "\n\n---\n\n")
        let memoryStats = "选入 \(memorySelection.records.count)/\(memorySelection.eligibleCount) 条，约 \(memorySelection.characterCount) 字符，省略 \(memorySelection.omittedCount) 条低相关记忆"
        let upstream = upstreamText(for: step.inputMode, priorExecutions: priorExecutions)
        let executionRule: String
        if step.executionAccess == .workspaceWrite {
            executionRule = "本步骤已由用户授予 Codex CLI workspace-write。必须检查并直接修改当前项目目录中的真实文件，运行与改动相关的测试或构建，并汇报实际变更；不要只给代码片段、伪代码或操作建议。不得修改项目目录之外的内容。"
        } else {
            executionRule = "本步骤运行在 Codex CLI read-only 沙箱中；只返回分析和产物，不修改本机文件。"
        }
        let isReviewStep = agent.role == .reviewer || step.reviewReturnStepID != nil
        let reviewProtocol = isReviewStep
            ? "审核完成后必须单独输出且只输出一个机器判定行：AIGO_VERDICT: PASS 或 AIGO_VERDICT: FAIL。不要同时输出两个判定；FAIL 时必须给出可直接执行的返工清单。判定行可以位于共享记忆段之前。"
            : ""
        let loopbackNotice: String
        if let latest = priorExecutions.last, latest.stepNumber > stepNumber {
            loopbackNotice = "这是审核失败后的回退重做。优先读取最近审核产物中的失败原因，逐项修复后再交回后续步骤。"
        } else {
            loopbackNotice = ""
        }
        let recoveryNotice = priorExecutions.last?.status == .interrupted
            ? "最近一次调用异常中断。其未完成输出只作为恢复线索；先核对当前项目真实文件，再补齐或修正，不要假定其中结论已经完成。"
            : ""

        return """
        你是 AiGo 科研编排项目“\(project.projectName)”中的“\(agent.name)”（\(agent.roleTitle)）。

        # 角色职责
        \(agent.instruction)

        # 当前任务
        第 \(stepNumber) 步：\(step.title)
        \(step.instruction)
        \(loopbackNotice)
        \(recoveryNotice)

        # 相关共享知识
        上下文预算：\(memoryStats)

        \(memoryText)

        # 有界上游交接
        \(upstream)

        # 工作规则
        - 用中文完成当前步骤，不越权替后续角色做最终决策。
        - 清楚区分事实、推断、建议和未知项；不得编造文献、数据、链接或实验结果。
        - \(executionRule)
        - 修改日志和运行摘要不会作为知识注入；不要依赖未在本提示中出现的旧上下文。
        - 输出必须可供下游角色复核和继续工作。
        - 除非任务明确要求长文，以完成任务所需的最短充分形式输出，不重复粘贴上游内容。
        \(reviewProtocol.isEmpty ? "" : "- \(reviewProtocol)")

        # 输出结构
        先给结论摘要，再给依据与过程，然后列出风险、假设和待确认事项。

        最后增加“## 共享记忆更新”，最多 10 条，每条只表达一个可独立更新的事实，并严格使用下列格式之一：
        - [事实|稳定短键] 可复核的事实、证据或发现
        - [决策|稳定短键] 已确定的方案或取舍
        - [约束|稳定短键] 后续步骤必须遵守的边界
        - [风险|稳定短键] 未决问题、冲突或失败条件
        - [后续|稳定短键] 明确的下一行动

        同一主题后续发生变化时复用相同“稳定短键”，AiGo 会更新原条目而不是继续叠加。不要把过程复述、寒暄、完整正文或修改日志写入共享记忆。
        """
    }

    private static func upstreamText(
        for mode: StepInputMode,
        priorExecutions: [StepExecution]
    ) -> String {
        guard !priorExecutions.isEmpty else { return "（暂无上游产物）" }

        switch mode {
        case .previous:
            guard let previous = priorExecutions.last else { return "（暂无上游产物）" }
            return bounded(
                "[步骤 \(previous.stepNumber)｜\(previous.agentName)｜尝试 \(previous.attempt)｜\(statusLabel(previous))]\n\(previous.output)",
                limit: upstreamCharacterBudget
            )

        case .accumulated:
            guard let latest = priorExecutions.last else { return "（暂无上游产物）" }
            let earlier = priorExecutions.dropLast()
            let recentEarlier = earlier.suffix(6)
            var parts: [String] = []
            if earlier.count > recentEarlier.count {
                parts.append("（更早的 \(earlier.count - recentEarlier.count) 个步骤仅通过相关共享知识继承，不重复附加原始输出。）")
            }
            for execution in recentEarlier {
                let digest = AutomaticMemoryService.compactHandoff(from: execution.output, limit: earlierDigestBudget)
                parts.append("[步骤 \(execution.stepNumber)｜\(execution.agentName)｜\(statusLabel(execution))｜压缩交接]\n\(digest)")
            }
            parts.append(
                "[最近步骤 \(latest.stepNumber)｜\(latest.agentName)｜\(statusLabel(latest))｜详细交接限长]\n"
                    + bounded(latest.output, limit: latestOutputBudget)
            )
            return bounded(parts.joined(separator: "\n\n---\n\n"), limit: upstreamCharacterBudget)
        }
    }

    private static func statusLabel(_ execution: StepExecution) -> String {
        execution.status == .interrupted ? "异常中断的部分产物" : "已完成产物"
    }

    private static func bounded(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        return String(value.prefix(max(0, limit - 20))) + "\n…（上游产物已按预算截断）"
    }
}
