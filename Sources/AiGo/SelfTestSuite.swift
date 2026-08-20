import Foundation

public struct AiGoSelfTestReport {
    public let passed: Int
    public let failures: [String]

    public var isSuccessful: Bool { failures.isEmpty }
}

public enum AiGoSelfTestSuite {
    @MainActor
    public static func run() async -> AiGoSelfTestReport {
        var passed = 0
        var failures: [String] = []

        func check(_ condition: Bool, _ name: String) {
            if condition { passed += 1 }
            else { failures.append(name) }
        }
        func recordFailure(_ message: String) { failures.append(message) }

        testAgentCapacity(check: check, recordFailure: recordFailure)
        testLongWorkflow(check: check, recordFailure: recordFailure)
        testDynamicProfiles(check: check)
        testWorkspaceLibrary(check: check, recordFailure: recordFailure)
        testLegacyDecoding(check: check, recordFailure: recordFailure)
        await testLegacyInterruptedArchiveMigration(check: check, recordFailure: recordFailure)
        testWorkflowDesign(check: check, recordFailure: recordFailure)
        testReviewVerdicts(check: check)
        testAutomaticMemory(check: check, recordFailure: recordFailure)
        testPromptComposition(check: check, recordFailure: recordFailure)
        testCLIJSONL(check: check)
        testCatalogParsing(check: check, recordFailure: recordFailure)
        await testWorkspaceEditing(check: check, recordFailure: recordFailure)
        await testCheckpointPersistence(check: check, recordFailure: recordFailure)
        await testRunMemoryRollback(check: check, recordFailure: recordFailure)
        await testParallelProjectRuns(check: check, recordFailure: recordFailure)
        await testCLIBackedOrchestration(check: check, recordFailure: recordFailure)
        await testInterruptedResume(check: check, recordFailure: recordFailure)
        await testReviewRollback(check: check, recordFailure: recordFailure)

        return AiGoSelfTestReport(passed: passed, failures: failures)
    }

    private static func testAgentCapacity(
        check: (_ condition: Bool, _ name: String) -> Void,
        recordFailure: (String) -> Void
    ) {
        var project = ProjectWorkspace.starter()
        guard let profileID = project.profiles.first?.id else {
            recordFailure("默认项目缺少 Codex CLI 配置")
            return
        }
        while project.agents.count < WorkspaceRules.maxAgents {
            project.agents.append(AgentSeat(name: "额外角色 \(project.agents.count + 1)", role: .custom, profileID: profileID))
        }
        check(project.agents.count == 8, "应可组织 8 个智能体")
        check(!WorkspaceRules.canAddAgent(to: project), "第 9 个智能体应被拒绝")
        project.agents.append(AgentSeat(name: "第九个", role: .custom, profileID: profileID))
        check(WorkspaceRules.validationMessage(for: project) == "智能体最多只能有 8 个。", "校验应报告 8 个上限")
        project.sanitize()
        check(project.agents.count == 8, "载入时应裁剪到 8 个智能体")
    }

    private static func testLongWorkflow(
        check: (_ condition: Bool, _ name: String) -> Void,
        recordFailure: (String) -> Void
    ) {
        var project = ProjectWorkspace.starter()
        guard let agentID = project.agents.first?.id else {
            recordFailure("默认项目缺少智能体")
            return
        }
        project.steps = (1...25).map { number in
            WorkflowStep(title: "步骤 \(number)", instruction: "完成第 \(number) 步", agentID: agentID)
        }
        check(project.steps.count == 25, "步骤数不应受智能体上限影响")
        check(WorkspaceRules.validationMessage(for: project) == nil, "25 步流程应通过校验")
    }

    private static func testDynamicProfiles(
        check: (_ condition: Bool, _ name: String) -> Void
    ) {
        let profile = CodexProfile(name: "跟随默认", reasoningEffort: .high)
        check(profile.modelID.isEmpty, "新配置应跟随 CLI 默认模型而非固定模型")
        var explicit = profile
        explicit.modelID = "future-codex-model"
        check(explicit.modelID == "future-codex-model", "配置应允许动态目录中的任意模型")
        check(ReasoningEffort.allCases.contains(.ultra), "推理强度应兼容 CLI 的 ultra 档")
    }

    private static func testWorkspaceLibrary(
        check: (_ condition: Bool, _ name: String) -> Void,
        recordFailure: (String) -> Void
    ) {
        var first = ProjectWorkspace.starter(name: "项目甲")
        first.projectBrief = "甲项目边界"
        var second = ProjectWorkspace.starter(name: "项目乙")
        second.projectBrief = "乙项目边界"
        second.cliSettings.executablePath = "/tmp/second-codex"
        second.projectDirectoryPath = "/tmp/research-project"
        let library = WorkspaceLibrary(schemaVersion: 5, selectedProjectID: second.id, projects: [first, second], updatedAt: Date())
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(library)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode(WorkspaceLibrary.self, from: data)
            check(decoded.projects.count == 2, "项目库应保存多个独立项目")
            check(decoded.selectedProjectID == second.id, "项目库应恢复当前项目")
            check(decoded.projects[0].projectBrief == "甲项目边界", "甲项目内容应独立恢复")
            check(decoded.projects[1].cliSettings.executablePath == "/tmp/second-codex", "Codex 设置应按项目隔离")
            check(decoded.projects[1].projectDirectoryPath == "/tmp/research-project", "项目工作路径应按项目保存")
        } catch {
            recordFailure("项目库编解码失败：\(error.localizedDescription)")
        }
    }

    private static func testLegacyDecoding(
        check: (_ condition: Bool, _ name: String) -> Void,
        recordFailure: (String) -> Void
    ) {
        let profileID = UUID()
        let agentID = UUID()
        let legacy: [String: Any] = [
            "schemaVersion": 1,
            "projectName": "0.1.0 旧项目",
            "projectBrief": "旧目标",
            "profiles": [[
                "id": profileID.uuidString,
                "name": "旧固定模型配置",
                "reasoningEffort": "high",
                "maxOutputTokens": 8_000
            ]],
            "agents": [[
                "id": agentID.uuidString,
                "name": "旧角色",
                "role": "architect",
                "instruction": "旧指令",
                "profileID": profileID.uuidString,
                "colorHex": "6E7BFF"
            ]],
            "steps": [[
                "id": UUID().uuidString,
                "title": "旧步骤",
                "instruction": "执行",
                "agentID": agentID.uuidString,
                "inputMode": "accumulated",
                "requiresApproval": false
            ]],
            "memories": [[
                "id": UUID().uuidString,
                "title": "旧人工记忆",
                "content": "可迁移内容",
                "source": "用户",
                "isApproved": true,
                "createdAt": "2026-01-01T00:00:00Z"
            ]]
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: legacy)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode(ProjectWorkspace.self, from: data)
            check(decoded.schemaVersion == 5, "旧项目应升级到 schema 5")
            check(decoded.profiles.first?.modelID == "", "旧固定模型配置应迁移为跟随 CLI 默认")
            check(decoded.memories.first?.kind == .migrated, "旧记忆应标记为迁移记忆")
            check(decoded.memories.first?.isActive == true, "旧已批准记忆应保持有效")
            check(decoded.projectDirectoryPath.isEmpty, "旧项目应默认使用 AiGo 托管路径")
            check(decoded.steps.first?.executionAccess == .workspaceWrite, "旧步骤应按新默认迁移为项目写入权限")
            check(decoded.steps.first?.maxReviewRetries == 1, "旧审核步骤应迁移为一次有界回环")
        } catch {
            recordFailure("0.1.0 迁移解码失败：\(error.localizedDescription)")
        }
    }

    @MainActor
    private static func testLegacyInterruptedArchiveMigration(
        check: (_ condition: Bool, _ name: String) -> Void,
        recordFailure: (String) -> Void
    ) async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aigo-legacy-recovery-\(UUID().uuidString)", isDirectory: true)
        let storage = root.appendingPathComponent("workspace.json")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            var project = ProjectWorkspace.starter(name: "0.1.2 中断迁移")
            guard let firstStep = project.steps.first,
                  let firstAgent = project.agents.first(where: { $0.id == firstStep.agentID }),
                  let reviewIndex = project.steps.firstIndex(where: { $0.reviewReturnStepID != nil }),
                  let returnID = project.steps[reviewIndex].reviewReturnStepID,
                  let returnIndex = project.steps.firstIndex(where: { $0.id == returnID }),
                  let returnAgent = project.agents.first(where: { $0.id == project.steps[returnIndex].agentID }),
                  let reviewAgent = project.agents.first(where: { $0.id == project.steps[reviewIndex].agentID }) else {
                recordFailure("旧版中断迁移测试缺少默认门控、审核或回退步骤")
                return
            }

            var completed = StepExecution(
                stepID: firstStep.id, stepNumber: 1, stepTitle: firstStep.title, agentName: firstAgent.name, attempt: 1,
                contextPreview: "", modelID: nil, reasoningEffort: "medium", executionAccess: firstStep.executionAccess
            )
            completed.status = .completed
            completed.output = "LEGACY_FIRST_DONE"
            completed.completedAt = Date(timeIntervalSinceNow: -20)

            let reviewStep = project.steps[reviewIndex]
            var failedReview = StepExecution(
                stepID: reviewStep.id, stepNumber: reviewIndex + 1, stepTitle: reviewStep.title, agentName: reviewAgent.name, attempt: 1,
                contextPreview: "", modelID: nil, reasoningEffort: "high", executionAccess: .readOnly
            )
            failedReview.status = .completed
            failedReview.output = "需要返工\nAIGO_VERDICT: FAIL"
            failedReview.completedAt = Date(timeIntervalSinceNow: -10)

            let returnStep = project.steps[returnIndex]
            var running = StepExecution(
                stepID: returnStep.id, stepNumber: returnIndex + 1, stepTitle: returnStep.title, agentName: returnAgent.name, attempt: 2,
                contextPreview: "LEGACY_CONTEXT", modelID: nil, reasoningEffort: "medium", executionAccess: returnStep.executionAccess
            )
            running.output = "LEGACY_PARTIAL_OUTPUT"

            let runID = UUID()
            project.runHistory = [
                RunSession(
                    id: runID,
                    phase: .cancelled,
                    startedAt: Date(timeIntervalSinceNow: -60),
                    completedAt: Date(),
                    currentStepIndex: returnIndex,
                    executions: [completed, failedReview, running],
                    events: [RunEvent(message: "运行已由用户取消。", kind: "warning")],
                    errorMessage: nil,
                    projectID: project.id
                )
            ]
            let legacyLibrary = WorkspaceLibrary(
                schemaVersion: 4,
                selectedProjectID: project.id,
                projects: [project],
                updatedAt: Date()
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(legacyLibrary).write(to: storage, options: .atomic)

            let store = WorkspaceStore(storageURL: storage)
            await store.flushPersistence()
            let recovered = store.recoverableRunCheckpoint
            check(recovered?.session.id == runID && recovered?.session.phase == .running, "schema 4 的不完整取消记录应重建为可恢复运行")
            check(recovered?.nextStepIndex == returnIndex, "旧版恢复应保留审核后的实际返工位置")
            check(recovered?.session.executions.last?.output == "LEGACY_PARTIAL_OUTPUT", "旧版恢复应保留最后调用的部分输出")
            check(recovered?.approvedGateIDs.contains(firstStep.id) == true, "旧版恢复应从已执行步骤重建人工批准集合")
            check(recovered?.reviewRetryCounts.first(where: { $0.reviewerStepID == reviewStep.id })?.retryCount == 1, "旧版恢复应从 FAIL 产物重建审核回环计数")
            let checkpointFile = root.appendingPathComponent("RunCheckpoints/\(project.id.uuidString).json")
            check(FileManager.default.fileExists(atPath: checkpointFile.path), "旧版恢复迁移应立即生成独立检查点文件")
        } catch {
            recordFailure("旧版不完整运行恢复迁移失败：\(error.localizedDescription)")
        }
    }

    private static func testWorkflowDesign(
        check: (_ condition: Bool, _ name: String) -> Void,
        recordFailure: (String) -> Void
    ) {
        let project = ProjectWorkspace.starter(name: "自动分配测试")
        guard let designer = project.agents.first(where: { $0.role == .architect }),
              let coder = project.agents.first(where: { $0.role == .coder }),
              let reviewer = project.agents.first(where: { $0.role == .reviewer }) else {
            recordFailure("自动分配测试缺少设计师、代码员或审核员")
            return
        }

        let json = """
        ```json
        {
          "summary": "先设计、再真实实现、最后审核并允许返工",
          "warnings": ["写入仅限项目目录"],
          "steps": [
            {
              "key": "design",
              "title": "确定实现边界",
              "instruction": "读取项目目标，明确模块、接口、验收标准和失败条件。",
              "agent_id": "\(designer.id.uuidString)",
              "input_mode": "accumulated",
              "execution_access": "read-only",
              "requires_approval": false,
              "review_return_to": null,
              "max_review_retries": 1
            },
            {
              "key": "implement",
              "title": "实现真实代码",
              "instruction": "按照设计完成模块并验证。",
              "agent_id": "\(coder.id.uuidString)",
              "input_mode": "accumulated",
              "execution_access": "workspace-write",
              "requires_approval": false,
              "review_return_to": null,
              "max_review_retries": 1
            },
            {
              "key": "review",
              "title": "审核实现",
              "instruction": "逐项核对文件和测试结果。",
              "agent_id": "\(reviewer.id.uuidString)",
              "input_mode": "accumulated",
              "execution_access": "read-only",
              "requires_approval": false,
              "review_return_to": "implement",
              "max_review_retries": 3
            }
          ]
        }
        ```
        """

        do {
            let proposal = try WorkflowDesignService.parse(json, project: project, designerAgentID: designer.id)
            check(proposal.steps.count == 3, "设计师草案应恢复完整步骤顺序")
            check(proposal.steps.allSatisfy {
                !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !$0.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }, "设计师草案的步骤名称和任务指令必须全部填入")
            check(proposal.steps[1].executionAccess == .workspaceWrite, "代码步骤应获得 workspace-write")
            check(proposal.steps[1].instruction.contains("真实文件") && proposal.steps[1].instruction.contains("运行相关测试或构建"), "代码任务应自动补充真实落盘与验证要求")
            check(proposal.steps[2].reviewReturnStepID == proposal.steps[1].id, "审核草案应解析指向更早步骤的回环")
            check(proposal.steps[2].maxReviewRetries == 3, "审核草案应保留有界回环次数")
            check(proposal.steps[2].instruction.contains("AIGO_VERDICT"), "审核任务应自动补充机器判定协议")
            check(WorkspaceRules.workflowValidationMessage(steps: proposal.steps, agents: project.agents) == nil, "完整设计师草案应可直接采用")
            var incomplete = proposal.steps
            incomplete[0].instruction = "  "
            check(WorkspaceRules.workflowValidationMessage(steps: incomplete, agents: project.agents)?.contains("缺少任务指令") == true, "用户清空草案任务指令后应禁止采用")
            check(project.steps.first(where: { step in
                project.agents.first(where: { $0.id == step.agentID })?.role == .coder
            })?.executionAccess == .workspaceWrite, "新项目默认代码步骤应允许真实写入")
            check(project.steps.allSatisfy { step in
                let role = project.agents.first(where: { $0.id == step.agentID })?.role
                return role == .reviewer ? step.executionAccess == .readOnly : step.executionAccess == .workspaceWrite
            }, "新项目应默认允许写项目文件，仅审核员保持只读")
        } catch {
            recordFailure("自动分配草案解析失败：\(error.localizedDescription)")
        }

        let invalidLoop = """
        {"steps":[
          {"key":"review","title":"审核","instruction":"审核","agent_id":"\(reviewer.id.uuidString)","review_return_to":"future"},
          {"key":"future","title":"未来步骤","instruction":"执行","agent_id":"\(coder.id.uuidString)"}
        ]}
        """
        do {
            _ = try WorkflowDesignService.parse(invalidLoop, project: project, designerAgentID: designer.id)
            check(false, "设计师草案不得接受指向未来步骤的回环")
        } catch {
            check(true, "设计师草案应拒绝前向或无限回环")
        }

        let longInstruction = String(repeating: "长指令", count: 2_000)
        let delegatedWrite = """
        {"steps":[{
          "key":"write-plan",
          "title":"写入研究方案文件",
          "instruction":"\(longInstruction)",
          "agent_id":"\(designer.id.uuidString)",
          "execution_access":"workspace-write"
        }]}
        """
        do {
            let proposal = try WorkflowDesignService.parse(delegatedWrite, project: project, designerAgentID: designer.id)
            check(proposal.steps[0].executionAccess == .workspaceWrite, "设计师声明的非审核写入步骤应保留 workspace-write")
            check(proposal.steps[0].instruction.contains("不得只返回伪代码"), "超长指令限长后仍必须保留真实写入安全要求")
            check(proposal.steps[0].instruction.count <= 5_000, "设计师单步指令应有硬长度上限")
        } catch {
            recordFailure("超长草案指令安全限长测试失败：\(error.localizedDescription)")
        }
    }

    private static func testReviewVerdicts(
        check: (_ condition: Bool, _ name: String) -> Void
    ) {
        check(ReviewVerdictParser.parse("结论\nAIGO_VERDICT: PASS") == .pass, "审核器应解析 AIGO PASS")
        check(ReviewVerdictParser.parse("**AIGO_VERDICT：FAIL**\n## 共享记忆更新") == .fail, "审核器应兼容 Markdown 和全角冒号的 FAIL")
        check(ReviewVerdictParser.parse("VERDICT: FAIL") == .fail, "审核器应兼容旧版 VERDICT 标记")
        check(ReviewVerdictParser.parse("建议未来可能 FAIL，但没有机器标记") == nil, "普通正文中的 FAIL 不得误触发回退")
        check(ReviewVerdictParser.parse("AIGO_VERDICT: FAIL\nAIGO_VERDICT: PASS") == .pass, "存在多次标记时应采用最后一个显式判定")
    }

    private static func testAutomaticMemory(
        check: (_ condition: Bool, _ name: String) -> Void,
        recordFailure: (String) -> Void
    ) {
        let original = ProjectWorkspace.starter(name: "记忆测试")
        let synchronized = AutomaticMemoryService.synchronizeMainline(in: original)
        check(synchronized.memories.first?.kind == .mainline, "应自动建立项目主脉络")
        check(synchronized.memories.first?.content.contains("当前编排顺序") == true, "主脉络应包含流程顺序")
        check(synchronized.memories.first?.content.contains("跟随 CLI 默认模型") == true, "主脉络应记录角色模型来源")

        var changed = synchronized
        changed.projectBrief = "新的研究边界"
        changed.steps[0].title = "重写后的第一步"
        let log = AutomaticMemoryService.changeLog(from: synchronized, to: changed)
        check(log?.kind == .changeLog, "蓝图变化应自动生成修改日志")
        check(log?.content.contains("项目目标") == true, "修改日志应记录目标变化")
        check(log?.content.contains("重写后的第一步") == true, "修改日志应记录步骤变化")

        guard let step = changed.steps.first, let agent = changed.agents.first else {
            recordFailure("记忆测试缺少默认步骤或角色")
            return
        }
        let execution = StepExecution(
            stepID: step.id,
            stepNumber: 1,
            stepTitle: step.title,
            agentName: agent.name,
            attempt: 1,
            contextPreview: "",
            modelID: nil,
            reasoningEffort: "high"
        )
        var finished = execution
        finished.output = "前文不应成为唯一重点\n\n## 共享记忆更新\n- [事实|main-result] MAIN_INSIGHT\n- [风险|risk-r1] 风险 R1\n- [约束|data-boundary] 只能使用已核验数据"
        let atomic = AutomaticMemoryService.stepMemories(from: finished, runID: UUID())
        check(atomic.count == 3, "步骤产物应拆成多条细粒度知识")
        check(atomic.map(\.kind) == [.finding, .risk, .constraint], "细粒度知识应保留事实、风险和约束类型")
        check(atomic.allSatisfy { $0.relatedStepID == step.id }, "步骤记忆应保留来源追踪")
        check(atomic.first?.stableKey == "topic:main-result", "模型提供的稳定短键应被规范化保存")

        var verdictAfterMemory = finished
        verdictAfterMemory.output = "## 共享记忆更新\n- [事实|verified] 已核验结果\n**AIGO_VERDICT：PASS**\n- [风险|must-not-enter] 判定行之后的文本"
        let verdictBounded = AutomaticMemoryService.stepMemories(from: verdictAfterMemory, runID: UUID())
        check(verdictBounded.count == 1 && verdictBounded[0].content == "已核验结果", "全角或 Markdown 审核判定行不得被收入共享记忆")

        var upsertProject = synchronized
        let firstDecision = MemoryRecord(
            kind: .decision,
            title: "方案选择",
            content: "采用方案 A",
            stableKey: "topic:architecture-choice"
        )
        let firstUpsert = AutomaticMemoryService.upserting(firstDecision, into: upsertProject)
        upsertProject = firstUpsert.project
        let revisedDecision = MemoryRecord(
            kind: .decision,
            title: "方案选择",
            content: "改为方案 B",
            stableKey: "topic:architecture-choice"
        )
        let secondUpsert = AutomaticMemoryService.upserting(revisedDecision, into: upsertProject)
        let matching = secondUpsert.project.memories.filter { $0.stableKey == "topic:architecture-choice" }
        check(matching.count == 1, "同一稳定键应更新原记录而不是重复追加")
        check(matching.first?.content == "改为方案 B" && matching.first?.revision == 2, "更新后的记忆应保留修订号和最新内容")

        let batchUpsert = AutomaticMemoryService.upserting([firstDecision, revisedDecision], into: synchronized)
        check(batchUpsert.records.count == 1, "同一步骤重复稳定键应在批量提交内合并")
        check(batchUpsert.records.first?.content == "改为方案 B" && batchUpsert.records.first?.revision == 2, "批量记忆应保留最后内容和连续修订号")

        var crowded = ProjectWorkspace.starter(name: "预算记忆")
        crowded = AutomaticMemoryService.synchronizeMainline(in: crowded)
        for number in 0..<40 {
            crowded = AutomaticMemoryService.appending(
                MemoryRecord(
                    kind: number.isMultiple(of: 3) ? .constraint : .finding,
                    title: "知识 \(number)",
                    content: String(repeating: "研究数据\(number) ", count: 55),
                    stableKey: "topic:knowledge-\(number)"
                ),
                to: crowded
            )
        }
        crowded = AutomaticMemoryService.appending(
            MemoryRecord(kind: .changeLog, title: "审计", content: "AUDIT_MUST_NOT_ENTER_PROMPT"),
            to: crowded
        )
        crowded = AutomaticMemoryService.appending(
            MemoryRecord(kind: .runSummary, title: "摘要", content: "SUMMARY_MUST_NOT_ENTER_PROMPT"),
            to: crowded
        )
        guard let crowdedStep = crowded.steps.first,
              let crowdedAgent = crowded.agents.first(where: { $0.id == crowdedStep.agentID }) else {
            recordFailure("预算记忆测试缺少默认步骤或角色")
            return
        }
        let selection = AutomaticMemoryService.selectMemories(from: crowded, agent: crowdedAgent, step: crowdedStep)
        check(selection.records.count <= AutomaticMemoryService.promptRecordLimit, "共享记忆注入应受 10 条硬上限约束")
        check(selection.characterCount <= AutomaticMemoryService.promptCharacterBudget, "共享记忆注入应受 6,000 字符硬预算约束")
        check(selection.omittedCount > 0, "超预算知识应被相关性筛选省略")
        check(!selection.records.contains(where: { $0.kind.isAudit }), "修改日志和运行摘要不得进入模型上下文")
    }

    private static func testPromptComposition(
        check: (_ condition: Bool, _ name: String) -> Void,
        recordFailure: (String) -> Void
    ) {
        var project = ProjectWorkspace.starter()
        project.memories = [
            MemoryRecord(kind: .decision, title: "自动决策", content: "ACTIVE_SENTINEL"),
            MemoryRecord(kind: .risk, title: "旧风险", content: "INACTIVE_SENTINEL", isActive: false),
            MemoryRecord(kind: .changeLog, title: "修改日志", content: "AUDIT_SENTINEL"),
            MemoryRecord(kind: .runSummary, title: "运行摘要", content: "SUMMARY_SENTINEL")
        ]
        guard let step = project.steps.first,
              let agent = project.agents.first(where: { $0.id == step.agentID }) else {
            recordFailure("提示词测试缺少默认步骤或角色")
            return
        }
        let prompt = PromptComposer.input(project: project, agent: agent, step: step, stepNumber: 1, priorExecutions: [])
        check(prompt.contains("ACTIVE_SENTINEL"), "提示词应自动包含有效共享记忆")
        check(!prompt.contains("INACTIVE_SENTINEL"), "提示词不应包含停用记忆")
        check(!prompt.contains("AUDIT_SENTINEL") && !prompt.contains("SUMMARY_SENTINEL"), "审计日志不得进入提示词")
        check(prompt.contains("## 共享记忆更新"), "提示词应要求产生下一步可继承内容")
        check(prompt.contains("[事实|稳定短键]"), "提示词应要求可去重的细粒度记忆格式")
        check(prompt.contains("workspace-write"), "新步骤提示词应明确默认项目写入权限")

        if let codeStep = project.steps.first(where: { $0.executionAccess == .workspaceWrite }),
           let codeAgent = project.agents.first(where: { $0.id == codeStep.agentID }) {
            let codePrompt = PromptComposer.input(
                project: project,
                agent: codeAgent,
                step: codeStep,
                stepNumber: 4,
                priorExecutions: []
            )
            check(codePrompt.contains("workspace-write"), "代码步骤提示词应明确写入权限")
            check(codePrompt.contains("直接修改当前项目目录中的真实文件"), "代码步骤不得只要求返回代码片段")
        } else {
            recordFailure("提示词测试缺少 workspace-write 代码步骤")
        }

        if let reviewStep = project.steps.first(where: { $0.reviewReturnStepID != nil }),
           let reviewAgent = project.agents.first(where: { $0.id == reviewStep.agentID }) {
            let reviewPrompt = PromptComposer.input(
                project: project,
                agent: reviewAgent,
                step: reviewStep,
                stepNumber: 5,
                priorExecutions: []
            )
            check(reviewPrompt.contains("AIGO_VERDICT: PASS") && reviewPrompt.contains("AIGO_VERDICT: FAIL"), "审核提示词应包含独立机器判定协议")
            check(reviewPrompt.contains("read-only"), "审核提示词应保持 CLI 只读边界")
        } else {
            recordFailure("提示词测试缺少审核步骤")
        }

        var previousOnly = step
        previousOnly.inputMode = .previous
        let firstExecution = StepExecution(
            stepID: UUID(), stepNumber: 1, stepTitle: "一", agentName: "甲", attempt: 1,
            contextPreview: "", modelID: nil, reasoningEffort: "medium"
        )
        var first = firstExecution
        first.status = .completed
        first.output = "UPSTREAM_ONE"
        var second = firstExecution
        second.id = UUID()
        second.stepNumber = 2
        second.output = "UPSTREAM_TWO"
        let previousPrompt = PromptComposer.input(
            project: project,
            agent: agent,
            step: previousOnly,
            stepNumber: 3,
            priorExecutions: [first, second]
        )
        check(!previousPrompt.contains("UPSTREAM_ONE") && previousPrompt.contains("UPSTREAM_TWO"), "仅上一步模式应隔离更早产物")

        var accumulated = step
        accumulated.inputMode = .accumulated
        let longExecutions: [StepExecution] = (1...30).map { number in
            var item = StepExecution(
                stepID: UUID(), stepNumber: number, stepTitle: "长步骤 \(number)", agentName: "角色 \(number)", attempt: 1,
                contextPreview: "", modelID: nil, reasoningEffort: "medium"
            )
            item.status = .completed
            let marker = number == 30 ? "LATEST_RAW_STEP_30" : "RAW_STEP_\(number)"
            item.output = marker + String(repeating: "X", count: 10_000)
            return item
        }
        let boundedPrompt = PromptComposer.input(
            project: project,
            agent: agent,
            step: accumulated,
            stepNumber: 31,
            priorExecutions: longExecutions
        )
        check(boundedPrompt.count < 25_000, "深层流程提示词应保持固定总量而非随步骤无限增长")
        check(!boundedPrompt.contains("RAW_STEP_1"), "很早的原始产物不应重复注入")
        check(boundedPrompt.contains("LATEST_RAW_STEP_30"), "累计模式应保留最近步骤的详细交接")
        check(boundedPrompt.contains("更早的 23 个步骤仅通过相关共享知识继承"), "累计模式应明确压缩早期步骤")
    }

    private static func testCLIJSONL(
        check: (_ condition: Bool, _ name: String) -> Void
    ) {
        check(
            CodexCLIService.parseJSONLine(#"{"type":"thread.started","thread_id":"thread_123"}"#) == .threadStarted("thread_123"),
            "JSONL 应解析 CLI thread.started"
        )
        check(
            CodexCLIService.parseJSONLine(#"{"type":"item.completed","item":{"type":"agent_message","text":"你好"}}"#) == .agentMessage("你好"),
            "JSONL 应解析智能体正文"
        )
        check(
            CodexCLIService.parseJSONLine(#"{"type":"turn.completed","usage":{"input_tokens":12,"cached_input_tokens":5,"output_tokens":7}}"#)
                == .completed(CodexCLIUsage(inputTokens: 12, cachedInputTokens: 5, outputTokens: 7)),
            "JSONL 应解析 token 用量"
        )
        check(
            CodexCLIService.parseJSONLine(#"{"type":"error","message":"CLI_ERROR"}"#) == .failed("CLI_ERROR"),
            "JSONL 应解析 CLI 错误"
        )
        let writeArguments = CodexCLIService.executionArguments(
            workingDirectory: URL(fileURLWithPath: "/tmp/aigo-code"),
            modelID: "",
            reasoningEffort: .high,
            executionAccess: .workspaceWrite
        )
        check(writeArguments.contains("workspace-write"), "代码步骤应把 workspace-write 传给 Codex CLI")
        check(!writeArguments.contains("--model"), "跟随 CLI 默认模型时不应固定 --model")
    }

    private static func testCatalogParsing(
        check: (_ condition: Bool, _ name: String) -> Void,
        recordFailure: (String) -> Void
    ) {
        let catalog = #"{"models":[{"slug":"future-sol","display_name":"Future Sol","default_reasoning_level":"max","supported_reasoning_levels":[{"effort":"low"},{"effort":"max"},{"effort":"ultra"}],"visibility":"list","priority":1},{"slug":"hidden-model","display_name":"Hidden","default_reasoning_level":"medium","supported_reasoning_levels":[{"effort":"medium"}],"visibility":"hide","priority":0}]}"#
        do {
            let models = try CodexCLIService.parseCatalog(catalog)
            check(models.map(\.modelID) == ["future-sol"], "模型目录应只保留 CLI 标记为可见的模型")
            check(models.first?.supportedReasoningEfforts == [.low, .max, .ultra], "模型目录应动态保留支持的推理档")
            check(models.first?.isDefault == true, "目录应标记首选模型")
        } catch {
            recordFailure("动态模型目录解析失败：\(error.localizedDescription)")
        }
    }

    @MainActor
    private static func testWorkspaceEditing(
        check: (_ condition: Bool, _ name: String) -> Void,
        recordFailure: (String) -> Void
    ) async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aigo-workspace-edit-\(UUID().uuidString)", isDirectory: true)
        let storage = root.appendingPathComponent("workspace.json")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let store = WorkspaceStore(storageURL: storage)
            guard !store.workspace.steps.isEmpty else {
                recordFailure("工作区编辑测试缺少默认步骤")
                return
            }
            let instruction = "STABLE_DRAFT_任务输入在自动记忆同步后仍应保留"
            store.workspace.steps[0].instruction = instruction
            store.workspace.projectDirectoryPath = root.path

            try? await Task.sleep(nanoseconds: 1_100_000_000)
            check(store.workspace.steps[0].instruction == instruction, "自动记忆同步不应清空正在编辑的任务指令")
            check(store.workspace.projectDirectoryPath == root.path, "项目路径编辑应保留在当前项目")
            let resolved = try store.projectDirectory(for: store.workspace.id)
            check(resolved.standardizedFileURL.path == root.standardizedFileURL.path, "CLI 应解析并使用自定义项目路径")

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let persisted = try decoder.decode(WorkspaceLibrary.self, from: Data(contentsOf: storage))
            check(persisted.projects.first?.steps.first?.instruction == instruction, "任务指令应稳定持久化到项目库")
            check(persisted.projects.first?.projectDirectoryPath == root.path, "自定义项目路径应持久化到项目库")
        } catch {
            recordFailure("工作区编辑与项目路径测试失败：\(error.localizedDescription)")
        }
    }

    @MainActor
    private static func testCheckpointPersistence(
        check: (_ condition: Bool, _ name: String) -> Void,
        recordFailure: (String) -> Void
    ) async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aigo-checkpoint-\(UUID().uuidString)", isDirectory: true)
        let storage = root.appendingPathComponent("workspace.json")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let store = WorkspaceStore(storageURL: storage)
            guard let step = store.workspace.steps.first,
                  let agent = store.workspace.agents.first(where: { $0.id == step.agentID }) else {
                recordFailure("检查点测试缺少默认步骤或角色")
                return
            }
            var execution = StepExecution(
                stepID: step.id,
                stepNumber: 1,
                stepTitle: step.title,
                agentName: agent.name,
                attempt: 1,
                contextPreview: "CHECKPOINT_CONTEXT",
                modelID: nil,
                reasoningEffort: "medium",
                executionAccess: step.executionAccess
            )
            execution.output = "PARTIAL_CHECKPOINT_OUTPUT"
            let session = RunSession(
                id: UUID(),
                phase: .running,
                startedAt: Date(),
                completedAt: nil,
                currentStepIndex: 0,
                executions: [execution],
                events: [RunEvent(message: "测试运行")],
                errorMessage: nil,
                projectID: store.workspace.id
            )
            let checkpoint = RunCheckpoint(
                projectID: store.workspace.id,
                session: session,
                nextStepIndex: 0,
                approvedGateIDs: [step.id],
                reviewRetryCounts: [ReviewRetryCheckpoint(reviewerStepID: step.id, retryCount: 2)]
            )
            store.saveRunCheckpoint(checkpoint, immediate: true)
            await store.flushPersistence()

            let checkpointFile = root.appendingPathComponent("RunCheckpoints/\(store.workspace.id.uuidString).json")
            check(FileManager.default.fileExists(atPath: checkpointFile.path), "异常运行检查点应作为项目独立原子文件保存")

            var streamed = checkpoint
            streamed.session.executions[0].output = "PARTIAL_STREAM_A"
            store.saveRunCheckpoint(streamed, immediate: false)
            streamed.session.executions[0].output = "PARTIAL_STREAM_LATEST"
            store.saveRunCheckpoint(streamed, immediate: false)
            try? await Task.sleep(nanoseconds: 750_000_000)
            await store.flushPersistence()

            let restored = WorkspaceStore(storageURL: storage)
            check(restored.recoverableRunCheckpoint?.session.id == session.id, "重新启动后应找到同一运行检查点")
            check(restored.recoverableRunCheckpoint?.session.executions.first?.output == "PARTIAL_STREAM_LATEST", "节流检查点应保存输出流的最新部分产物")
            check(restored.recoverableRunCheckpoint?.reviewRetryCounts.first?.retryCount == 2, "检查点应保留审核回环次数")

            if let recovered = restored.recoverableRunCheckpoint {
                _ = restored.restartFromCheckpoint(recovered)
            }
            await restored.flushPersistence()
            let afterRestart = WorkspaceStore(storageURL: storage)
            check(afterRestart.recoverableRunCheckpoint == nil, "选择重新开始后不应再次弹出旧检查点")
            check(afterRestart.workspace.runHistory.first?.executions.first?.status == .interrupted, "重新开始前应把异常调用保留为中断归档")
        } catch {
            recordFailure("异常运行检查点持久化测试失败：\(error.localizedDescription)")
        }
    }

    @MainActor
    private static func testRunMemoryRollback(
        check: (_ condition: Bool, _ name: String) -> Void,
        recordFailure: (String) -> Void
    ) async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aigo-memory-rollback-\(UUID().uuidString)", isDirectory: true)
        let storage = root.appendingPathComponent("workspace.json")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let store = WorkspaceStore(storageURL: storage)
            let projectID = store.workspace.id
            let original = MemoryRecord(
                kind: .decision,
                title: "运行前决策",
                content: "BASELINE_DECISION",
                source: "既有知识",
                stableKey: "topic:rollback-stable-key"
            )
            store.integrateAutomaticMemory(original, projectID: projectID)

            let runID = UUID()
            check(store.beginRunMemoryTransaction(projectID: projectID, runID: runID), "新运行应建立项目级记忆事务")
            let replacement = MemoryRecord(
                kind: .decision,
                title: "运行中覆盖",
                content: "INTERRUPTED_REPLACEMENT",
                source: "中断运行",
                relatedRunID: runID,
                stableKey: "topic:rollback-stable-key"
            )
            let addition = MemoryRecord(
                kind: .finding,
                title: "运行中新知识",
                content: "INTERRUPTED_ADDITION",
                source: "中断运行",
                relatedRunID: runID,
                stableKey: "topic:rollback-addition"
            )
            store.integrateAutomaticMemories([replacement, addition], projectID: projectID)
            check(store.workspace.memories.contains(where: { $0.content == "INTERRUPTED_REPLACEMENT" }), "运行中应能更新稳定键知识")

            guard let step = store.workspace.steps.first,
                  let agent = store.workspace.agents.first(where: { $0.id == step.agentID }) else {
                recordFailure("记忆回滚测试缺少默认步骤或角色")
                return
            }
            var execution = StepExecution(
                stepID: step.id,
                stepNumber: 1,
                stepTitle: step.title,
                agentName: agent.name,
                attempt: 1,
                contextPreview: "ROLLBACK_CONTEXT",
                modelID: nil,
                reasoningEffort: "medium",
                executionAccess: step.executionAccess
            )
            execution.output = "INTERRUPTED_PARTIAL_OUTPUT"
            let session = RunSession(
                id: runID,
                phase: .running,
                startedAt: Date(timeIntervalSinceNow: -5),
                completedAt: nil,
                currentStepIndex: 0,
                executions: [execution],
                events: [],
                errorMessage: nil,
                projectID: projectID
            )
            let checkpoint = RunCheckpoint(
                projectID: projectID,
                session: session,
                nextStepIndex: 0,
                approvedGateIDs: [],
                reviewRetryCounts: []
            )
            store.saveRunCheckpoint(checkpoint, immediate: true)
            await store.flushPersistence()

            check(store.restartFromCheckpoint(checkpoint), "重新开始应原子回滚中断运行")
            await store.flushPersistence()

            let restored = WorkspaceStore(storageURL: storage)
            let restoredStable = restored.workspace.memories.first(where: { $0.stableKey == "topic:rollback-stable-key" })
            check(restoredStable?.id == original.id && restoredStable?.content == "BASELINE_DECISION", "重新开始应精确恢复被稳定键覆盖的运行前知识")
            check(!restored.workspace.memories.contains(where: { $0.relatedRunID == runID }), "重新开始后不得残留本次中断运行的共享记忆")
            check(!restored.workspace.memories.contains(where: { $0.content == "INTERRUPTED_ADDITION" }), "重新开始应删除本次运行新增知识")
            check(restored.workspace.runHistory.first?.id == runID && restored.workspace.runHistory.first?.phase == .cancelled, "回滚记忆时仍应保留中断运行审计记录")
            let checkpointURL = root.appendingPathComponent("RunCheckpoints/\(projectID.uuidString).json")
            let baselineURL = root.appendingPathComponent("RunMemoryBaselines/\(projectID.uuidString).json")
            check(!FileManager.default.fileExists(atPath: checkpointURL.path) && !FileManager.default.fileExists(atPath: baselineURL.path), "回滚提交后应同时清理检查点和记忆基线")

            let legacyStorage = root.appendingPathComponent("legacy-workspace.json")
            var legacyProject = ProjectWorkspace.starter(name: "旧版重新开始残留")
            let restartedRunID = UUID()
            let manuallyCancelledRunID = UUID()
            legacyProject.memories.append(
                MemoryRecord(
                    kind: .finding,
                    title: "旧版错误残留",
                    content: "LEGACY_RESTART_RESIDUE",
                    source: "0.1.3",
                    relatedRunID: restartedRunID
                )
            )
            legacyProject.memories.append(
                MemoryRecord(
                    kind: .finding,
                    title: "普通取消保留",
                    content: "MANUAL_CANCEL_MEMORY",
                    source: "用户停止",
                    relatedRunID: manuallyCancelledRunID
                )
            )
            legacyProject.runHistory = [
                RunSession(
                    id: restartedRunID,
                    phase: .cancelled,
                    startedAt: Date(timeIntervalSinceNow: -20),
                    completedAt: Date(timeIntervalSinceNow: -10),
                    currentStepIndex: nil,
                    executions: [],
                    events: [RunEvent(message: "用户选择重新开始；异常运行已保留为中断归档。", kind: "warning")],
                    errorMessage: nil,
                    projectID: legacyProject.id
                ),
                RunSession(
                    id: manuallyCancelledRunID,
                    phase: .cancelled,
                    startedAt: Date(timeIntervalSinceNow: -9),
                    completedAt: Date(),
                    currentStepIndex: nil,
                    executions: [],
                    events: [RunEvent(message: "运行已由用户取消。", kind: "warning")],
                    errorMessage: nil,
                    projectID: legacyProject.id
                )
            ]
            let legacyLibrary = WorkspaceLibrary(
                schemaVersion: 5,
                selectedProjectID: legacyProject.id,
                projects: [legacyProject],
                updatedAt: Date()
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(legacyLibrary).write(to: legacyStorage, options: .atomic)
            let migrated = WorkspaceStore(storageURL: legacyStorage)
            check(!migrated.workspace.memories.contains(where: { $0.content == "LEGACY_RESTART_RESIDUE" }), "升级时应清理 0.1.3 已知重新开始残留")
            check(migrated.workspace.memories.contains(where: { $0.content == "MANUAL_CANCEL_MEMORY" }), "升级清理不得误删普通手动停止的知识")
            check(migrated.migrationMessage?.contains("已清理旧版") == true, "升级时应说明已清理旧版残留记忆")
        } catch {
            recordFailure("运行记忆事务回滚测试失败：\(error.localizedDescription)")
        }
    }

    @MainActor
    private static func testParallelProjectRuns(
        check: (_ condition: Bool, _ name: String) -> Void,
        recordFailure: (String) -> Void
    ) async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aigo-parallel-\(UUID().uuidString)", isDirectory: true)
        let storage = root.appendingPathComponent("workspace.json")
        let executable = root.appendingPathComponent("fake-codex")
        let script = """
        #!/bin/zsh
        input="$(/bin/cat)"
        /bin/echo '{"type":"thread.started","thread_id":"parallel_thread"}'
        /bin/sleep 0.35
        if [[ "$input" == *"PROJECT_ALPHA_SENTINEL"* ]]; then
          /bin/echo '{"type":"item.completed","item":{"type":"agent_message","text":"PARALLEL_ALPHA\\n\\n## 共享记忆更新\\n- [事实|parallel-result] PARALLEL_ALPHA"}}'
        else
          /bin/echo '{"type":"item.completed","item":{"type":"agent_message","text":"PARALLEL_BETA\\n\\n## 共享记忆更新\\n- [事实|parallel-result] PARALLEL_BETA"}}'
        fi
        /bin/echo '{"type":"turn.completed","usage":{"input_tokens":8,"output_tokens":4}}'
        """

        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try script.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            defer { try? FileManager.default.removeItem(at: root) }

            let store = WorkspaceStore(storageURL: storage)
            guard let alphaAgentID = store.workspace.agents.first?.id else {
                recordFailure("并行项目测试缺少 Alpha 角色")
                return
            }
            store.workspace.projectName = "并行 Alpha"
            store.workspace.cliSettings.executablePath = executable.path
            store.workspace.projectDirectoryPath = root.path
            store.workspace.steps = [
                WorkflowStep(
                    title: "Alpha 独立任务",
                    instruction: "PROJECT_ALPHA_SENTINEL",
                    agentID: alphaAgentID,
                    executionAccess: .workspaceWrite
                )
            ]
            let alphaID = store.workspace.id

            store.addProject()
            guard let betaAgentID = store.workspace.agents.first?.id else {
                recordFailure("并行项目测试缺少 Beta 角色")
                return
            }
            store.workspace.projectName = "并行 Beta"
            store.workspace.cliSettings.executablePath = executable.path
            store.workspace.projectDirectoryPath = root.path
            store.workspace.steps = [
                WorkflowStep(
                    title: "Beta 独立任务",
                    instruction: "PROJECT_BETA_SENTINEL",
                    agentID: betaAgentID,
                    executionAccess: .workspaceWrite
                )
            ]
            let betaID = store.workspace.id

            let registry = ProjectRunRegistry()
            let betaEngine = registry.engine(for: betaID)
            check(RunLaunchCoordinator.startNew(store: store, engine: betaEngine), "Beta 项目应能启动独立运行")
            store.selectProject(alphaID)
            let alphaEngine = registry.engine(for: alphaID)
            check(RunLaunchCoordinator.startNew(store: store, engine: alphaEngine), "Alpha 项目应能在 Beta 运行时启动")
            check(alphaEngine.isActive && betaEngine.isActive && registry.activeCount == 2, "两个项目应同时拥有活跃 Codex CLI 执行器")

            for _ in 0..<240 where alphaEngine.isActive || betaEngine.isActive {
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
            await store.flushPersistence()

            check(alphaEngine.session.phase == .completed && betaEngine.session.phase == .completed, "两个并行项目都应独立完成")
            let alpha = store.projects.first(where: { $0.id == alphaID })
            let beta = store.projects.first(where: { $0.id == betaID })
            check(alpha?.runHistory.first?.id == alphaEngine.session.id && beta?.runHistory.first?.id == betaEngine.session.id, "并行运行应分别归档到所属项目")
            check(alpha?.memories.contains(where: { $0.content.contains("PARALLEL_ALPHA") }) == true, "Alpha 产物不得因切换项目而丢失")
            check(beta?.memories.contains(where: { $0.content.contains("PARALLEL_BETA") }) == true, "Beta 后台产物应写回 Beta 而不是当前项目")
            check(alpha?.memories.contains(where: { $0.content.contains("PARALLEL_BETA") }) != true, "并行项目共享记忆必须隔离")
            check(beta?.memories.contains(where: { $0.content.contains("PARALLEL_ALPHA") }) != true, "后台回调不得串写另一个项目")
            check(alpha?.memories.contains(where: { $0.kind == .runSummary }) == true && beta?.memories.contains(where: { $0.kind == .runSummary }) == true, "每个项目应在单次收尾事务中生成自己的运行摘要")
            let alphaCheckpoint = root.appendingPathComponent("RunCheckpoints/\(alphaID.uuidString).json")
            let betaCheckpoint = root.appendingPathComponent("RunCheckpoints/\(betaID.uuidString).json")
            check(!FileManager.default.fileExists(atPath: alphaCheckpoint.path) && !FileManager.default.fileExists(atPath: betaCheckpoint.path), "并行项目正常收尾后应各自清理恢复检查点")
        } catch {
            recordFailure("项目并行运行测试失败：\(error.localizedDescription)")
        }
    }

    @MainActor
    private static func testCLIBackedOrchestration(
        check: (_ condition: Bool, _ name: String) -> Void,
        recordFailure: (String) -> Void
    ) async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aigo-selftest-\(UUID().uuidString)", isDirectory: true)
        let executable = root.appendingPathComponent("fake-codex")
        let script = """
        #!/bin/zsh
        if [[ "$1" == "--version" ]]; then
          /bin/echo 'codex-cli test-0.1.4'
        elif [[ "$1" == "login" ]]; then
          /bin/echo 'Logged in using ChatGPT' >&2
        elif [[ "$1" == "debug" ]]; then
          /bin/echo '{"models":[{"slug":"fake-dynamic-model","display_name":"Fake Dynamic Model","default_reasoning_level":"medium","supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"},{"effort":"high"}],"visibility":"list","priority":1}]}'
        else
          /bin/cat >/dev/null
          /bin/echo '{"type":"thread.started","thread_id":"fake_thread"}'
          /bin/echo '{"type":"item.completed","item":{"type":"agent_message","text":"# FAKE_RESULT\\n\\n## 共享记忆更新\\n- [事实|fake-shared] FAKE_SHARED"}}'
          /bin/echo '{"type":"turn.completed","usage":{"input_tokens":11,"cached_input_tokens":2,"output_tokens":5}}'
        fi
        """

        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try script.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            defer { try? FileManager.default.removeItem(at: root) }

            let inspection = try await CodexCLIService.inspect(executablePath: executable.path)
            check(inspection.loginSummary.contains("Logged in"), "CLI 检测应复用登录状态")
            check(inspection.models.first?.modelID == "fake-dynamic-model", "CLI 检测应返回动态模型")

            var project = ProjectWorkspace.starter(name: "CLI 编排测试")
            project.cliSettings.executablePath = executable.path
            project.steps = Array(project.steps.prefix(2))
            for index in project.steps.indices {
                project.steps[index].requiresApproval = false
                project.steps[index].reviewReturnStepID = nil
            }
            var generatedMemories: [MemoryRecord] = []
            var memoryBatchCount = 0
            var archived: RunSession?
            let engine = OrchestrationEngine()
            engine.start(
                workspace: project,
                workingDirectory: root,
                onMemory: {
                    memoryBatchCount += 1
                    generatedMemories.append(contentsOf: $0)
                },
                onCheckpoint: { _, _ in },
                onFinish: { archived = $0 }
            )
            for _ in 0..<160 where engine.isActive {
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
            check(engine.session.phase == .completed, "本机 CLI 编排应完成")
            check(engine.session.executions.map(\.stepNumber) == [1, 2], "CLI 编排应严格保持 1 → 2 顺序")
            check(engine.session.executions.allSatisfy { $0.output.contains("FAKE_RESULT") }, "每一步应读取 CLI agent_message")
            check(generatedMemories.filter { $0.kind == .finding }.count == 2, "每一步应自动提取细粒度共享知识")
            check(generatedMemories.filter { $0.kind == .finding }.last?.revision == 1, "相同内容与稳定键不应虚增修订号")
            check(!generatedMemories.contains(where: { $0.kind == .runSummary }), "编排引擎应把运行摘要留给单次收尾事务，而不是额外触发记忆写入")
            check(memoryBatchCount == 2, "两步知识应按步骤批量更新，运行摘要由收尾事务合并")
            check(archived?.id == engine.session.id, "CLI 运行应进入项目归档回调")
        } catch {
            recordFailure("本机 CLI 编排集成测试失败：\(error.localizedDescription)")
        }
    }

    @MainActor
    private static func testInterruptedResume(
        check: (_ condition: Bool, _ name: String) -> Void,
        recordFailure: (String) -> Void
    ) async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aigo-resume-\(UUID().uuidString)", isDirectory: true)
        let executable = root.appendingPathComponent("fake-codex")
        let script = """
        #!/bin/zsh
        input="$(/bin/cat)"
        /bin/echo '{"type":"thread.started","thread_id":"resumed_thread"}'
        if [[ "$input" == *"PARTIAL_RESUME_SENTINEL"* ]]; then
          /bin/echo '{"type":"item.completed","item":{"type":"agent_message","text":"PARTIAL_WAS_REUSED\\n\\n## 共享记忆更新\\n- [事实|resume-result] RESUME_OK"}}'
        else
          /bin/echo '{"type":"error","message":"partial output missing from resume prompt"}'
          exit 7
        fi
        /bin/echo '{"type":"turn.completed","usage":{"input_tokens":9,"output_tokens":4}}'
        """

        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try script.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            defer { try? FileManager.default.removeItem(at: root) }

            var project = ProjectWorkspace.starter(name: "异常恢复测试")
            project.cliSettings.executablePath = executable.path
            guard let agent = project.agents.first else {
                recordFailure("异常恢复测试缺少智能体")
                return
            }
            let firstStep = WorkflowStep(title: "已完成步骤", instruction: "先完成基础工作。", agentID: agent.id)
            let secondStep = WorkflowStep(title: "中断步骤", instruction: "核对部分产物并完成。", agentID: agent.id, requiresApproval: true)
            project.steps = [firstStep, secondStep]

            var completed = StepExecution(
                stepID: firstStep.id, stepNumber: 1, stepTitle: firstStep.title, agentName: agent.name, attempt: 1,
                contextPreview: "", modelID: nil, reasoningEffort: "medium", executionAccess: .workspaceWrite
            )
            completed.status = .completed
            completed.output = "FIRST_STEP_DONE"
            completed.completedAt = Date()
            var interrupted = StepExecution(
                stepID: secondStep.id, stepNumber: 2, stepTitle: secondStep.title, agentName: agent.name, attempt: 1,
                contextPreview: "OLD_CONTEXT", modelID: nil, reasoningEffort: "medium", executionAccess: .workspaceWrite
            )
            interrupted.output = "PARTIAL_RESUME_SENTINEL"
            interrupted.cliThreadID = "old_thread"
            let originalRunID = UUID()
            let session = RunSession(
                id: originalRunID,
                phase: .running,
                startedAt: Date(timeIntervalSinceNow: -30),
                completedAt: nil,
                currentStepIndex: 1,
                executions: [completed, interrupted],
                events: [],
                errorMessage: nil,
                projectID: project.id
            )
            let checkpoint = RunCheckpoint(
                projectID: project.id,
                session: session,
                nextStepIndex: 1,
                approvedGateIDs: [secondStep.id],
                reviewRetryCounts: []
            )

            var sawImmediateCheckpoint = false
            var archived: RunSession?
            let engine = OrchestrationEngine()
            engine.resume(
                workspace: project,
                workingDirectory: root,
                checkpoint: checkpoint,
                onMemory: { _ in },
                onCheckpoint: { snapshot, immediate in
                    if snapshot != nil && immediate { sawImmediateCheckpoint = true }
                },
                onFinish: { archived = $0 }
            )
            for _ in 0..<200 where engine.isActive {
                try? await Task.sleep(nanoseconds: 25_000_000)
            }

            check(engine.session.phase == .completed, "从检查点继续后应完成剩余流程")
            check(engine.session.id == originalRunID, "继续运行应保留原运行身份而非伪造新任务")
            check(engine.session.executions.map(\.stepNumber) == [1, 2, 2], "恢复时不应重跑已完成步骤，只重试中断步骤")
            check(engine.session.executions[1].status == .interrupted, "上次正在运行的调用应明确标记为异常中断")
            check(engine.session.executions[2].attempt == 2, "恢复后的中断步骤应记录为下一次尝试")
            check(engine.session.executions[2].output.contains("PARTIAL_WAS_REUSED"), "恢复调用应使用已保存的部分产物")
            check(engine.session.executions[2].contextPreview.contains("异常中断") && engine.session.executions[2].contextPreview.contains("PARTIAL_RESUME_SENTINEL"), "恢复提示应标明部分产物的不确定边界")
            check(sawImmediateCheckpoint, "恢复边界应立即保存；检查点清理由项目收尾事务统一提交")
            check(archived?.id == originalRunID, "恢复完成后应归档原运行会话")
        } catch {
            recordFailure("异常中断恢复集成测试失败：\(error.localizedDescription)")
        }
    }

    @MainActor
    private static func testReviewRollback(
        check: (_ condition: Bool, _ name: String) -> Void,
        recordFailure: (String) -> Void
    ) async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aigo-review-loop-\(UUID().uuidString)", isDirectory: true)
        let executable = root.appendingPathComponent("fake-codex")
        let script = """
        #!/bin/zsh
        input="$(/bin/cat)"
        /bin/echo '{"type":"thread.started","thread_id":"loop_thread"}'
        if [[ "$input" == *"REVIEW_TARGET_SENTINEL"* ]]; then
          if [[ "$*" != *"read-only"* ]]; then
            /bin/echo '{"type":"error","message":"review step did not use read-only"}'
            exit 8
          fi
          count_file="$0.review-count"
          count=0
          if [[ -f "$count_file" ]]; then
            read count < "$count_file"
          fi
          count=$((count + 1))
          /bin/echo "$count" > "$count_file"
          if [[ "$count" -eq 1 ]]; then
            /bin/echo '{"type":"item.completed","item":{"type":"agent_message","text":"发现实现缺陷，需要返工。\\n\\n**AIGO_VERDICT：FAIL**\\n\\n## 共享记忆更新\\n- [风险|failed-review] FAILED_REVIEW_MEMORY"}}'
          else
            /bin/echo '{"type":"item.completed","item":{"type":"agent_message","text":"返工问题已修复。\\n\\nAIGO_VERDICT: PASS\\n\\n## 共享记忆更新\\n- [事实|review-pass] REVIEW_PASS"}}'
          fi
        else
          if [[ "$*" != *"workspace-write"* ]]; then
            /bin/echo '{"type":"error","message":"code step did not use workspace-write"}'
            exit 9
          fi
          /bin/echo 'written by code step' > "$PWD/aigo-code-step-proof.txt"
          /bin/echo '{"type":"item.completed","item":{"type":"agent_message","text":"CODE_WRITTEN_AND_TESTED\\n\\n## 共享记忆更新\\n- [事实|code-result] CODE_RESULT"}}'
        fi
        /bin/echo '{"type":"turn.completed","usage":{"input_tokens":13,"cached_input_tokens":1,"output_tokens":8}}'
        """

        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try script.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            defer { try? FileManager.default.removeItem(at: root) }

            var project = ProjectWorkspace.starter(name: "审核回环测试")
            project.cliSettings.executablePath = executable.path
            guard let coder = project.agents.first(where: { $0.role == .coder }),
                  let reviewer = project.agents.first(where: { $0.role == .reviewer }) else {
                recordFailure("审核回环测试缺少代码员或审核员")
                return
            }
            let code = WorkflowStep(
                title: "真实代码返工",
                instruction: "CODE_TARGET_SENTINEL：直接修改文件并验证。",
                agentID: coder.id,
                executionAccess: .workspaceWrite
            )
            let review = WorkflowStep(
                title: "审核代码",
                instruction: "REVIEW_TARGET_SENTINEL：检查实现。",
                agentID: reviewer.id,
                executionAccess: .readOnly,
                reviewReturnStepID: code.id,
                maxReviewRetries: 2
            )
            project.steps = [code, review]

            var generatedMemories: [MemoryRecord] = []
            var archived: RunSession?
            let engine = OrchestrationEngine()
            engine.start(
                workspace: project,
                workingDirectory: root,
                onMemory: { generatedMemories.append(contentsOf: $0) },
                onCheckpoint: { _, _ in },
                onFinish: { archived = $0 }
            )
            for _ in 0..<320 where engine.isActive {
                try? await Task.sleep(nanoseconds: 25_000_000)
            }

            check(engine.session.phase == .completed, "审核首次 FAIL、返工后 PASS 应完成流程")
            check(engine.session.executions.map(\.stepNumber) == [1, 2, 1, 2], "审核 FAIL 应真实回到目标步骤并重新审核")
            check(engine.session.executions.map(\.attempt) == [1, 1, 2, 2], "回环执行应保留每一步尝试次数")
            check(engine.session.events.contains(where: { $0.kind == "retry" && $0.message.contains("第 1/2 次回环") }), "运行监控应记录审核回环次数")
            check(engine.session.executions[2].contextPreview.contains("这是审核失败后的回退重做"), "返工步骤应明确收到回退状态")
            check(engine.session.executions[2].contextPreview.contains("发现实现缺陷"), "返工步骤应收到最近审核失败原因")
            check(engine.session.executions[0].executionAccess == .workspaceWrite, "代码执行记录应保存写入权限")
            check(engine.session.executions[1].executionAccess == .readOnly, "审核执行记录应保持只读")
            check(FileManager.default.fileExists(atPath: root.appendingPathComponent("aigo-code-step-proof.txt").path), "代码步骤子进程应能在当前项目目录真实落盘")
            check(!generatedMemories.contains(where: { $0.content.contains("FAILED_REVIEW_MEMORY") }), "FAIL 审核内容不得写入有效共享知识")
            check(generatedMemories.contains(where: { $0.content.contains("REVIEW_PASS") }), "PASS 审核结果可进入共享知识")
            check(archived?.phase == .completed, "带回环的完成运行应正确归档")
        } catch {
            recordFailure("审核回环集成测试失败：\(error.localizedDescription)")
        }
    }
}
