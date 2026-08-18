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
        testAutomaticMemory(check: check, recordFailure: recordFailure)
        testPromptComposition(check: check, recordFailure: recordFailure)
        testCLIJSONL(check: check)
        testCatalogParsing(check: check, recordFailure: recordFailure)
        await testWorkspaceEditing(check: check, recordFailure: recordFailure)
        await testCLIBackedOrchestration(check: check, recordFailure: recordFailure)

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
        let library = WorkspaceLibrary(schemaVersion: 3, selectedProjectID: second.id, projects: [first, second], updatedAt: Date())
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
            check(decoded.schemaVersion == 3, "旧项目应升级到 schema 3")
            check(decoded.profiles.first?.modelID == "", "旧固定模型配置应迁移为跟随 CLI 默认")
            check(decoded.memories.first?.kind == .migrated, "旧记忆应标记为迁移记忆")
            check(decoded.memories.first?.isActive == true, "旧已批准记忆应保持有效")
            check(decoded.projectDirectoryPath.isEmpty, "旧项目应默认使用 AiGo 托管路径")
        } catch {
            recordFailure("0.1.0 迁移解码失败：\(error.localizedDescription)")
        }
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
        check(selection.records.count <= AutomaticMemoryService.promptRecordLimit, "共享记忆注入应受 14 条硬上限约束")
        check(selection.characterCount <= AutomaticMemoryService.promptCharacterBudget, "共享记忆注入应受 9,000 字符硬预算约束")
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
        check(prompt.contains("read-only"), "提示词应明确 CLI 只读边界")

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
        check(boundedPrompt.contains("更早的 21 个步骤仅通过相关共享知识继承"), "累计模式应明确压缩早期步骤")
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
    private static func testCLIBackedOrchestration(
        check: (_ condition: Bool, _ name: String) -> Void,
        recordFailure: (String) -> Void
    ) async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("aigo-selftest-\(UUID().uuidString)", isDirectory: true)
        let executable = root.appendingPathComponent("fake-codex")
        let script = """
        #!/bin/zsh
        if [[ "$1" == "--version" ]]; then
          /bin/echo 'codex-cli test-0.1.1'
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
            var archived: RunSession?
            let engine = OrchestrationEngine()
            engine.start(
                workspace: project,
                workingDirectory: root,
                onMemory: { generatedMemories.append($0) },
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
            check(generatedMemories.last?.kind == .runSummary, "运行结束应自动写入运行摘要")
            check(archived?.id == engine.session.id, "CLI 运行应进入项目归档回调")
        } catch {
            recordFailure("本机 CLI 编排集成测试失败：\(error.localizedDescription)")
        }
    }
}
