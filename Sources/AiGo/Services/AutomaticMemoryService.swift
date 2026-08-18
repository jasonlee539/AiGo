import Foundation

struct MemorySelection {
    var records: [MemoryRecord]
    var eligibleCount: Int
    var omittedCount: Int
    var characterCount: Int
}

struct MemoryUpsertResult {
    var project: ProjectWorkspace
    var record: MemoryRecord
}

enum AutomaticMemoryService {
    static let promptCharacterBudget = 9_000
    static let promptRecordLimit = 14
    static let maximumAtomicRecordsPerStep = 10

    static func synchronizeMainline(in project: ProjectWorkspace) -> ProjectWorkspace {
        var updated = project
        let content = mainlineContent(for: project)
        let title = "\(project.projectName) · 项目主脉络"
        if let index = updated.memories.firstIndex(where: { $0.kind == .mainline }) {
            if updated.memories[index].content != content || updated.memories[index].title != title {
                updated.memories[index].title = title
                updated.memories[index].content = content
                updated.memories[index].revision += 1
                updated.memories[index].updatedAt = Date()
                updated.memories[index].source = "AiGo 自动同步"
                updated.memories[index].stableKey = "system:mainline"
                updated.memories[index].isActive = true
            } else if updated.memories[index].stableKey == nil {
                updated.memories[index].stableKey = "system:mainline"
            }
        } else {
            updated.memories.insert(
                MemoryRecord(
                    kind: .mainline,
                    title: title,
                    content: content,
                    source: "AiGo 自动同步",
                    stableKey: "system:mainline"
                ),
                at: 0
            )
        }
        return compacted(updated)
    }

    static func changeLog(from old: ProjectWorkspace, to new: ProjectWorkspace) -> MemoryRecord? {
        var changes: [String] = []

        if old.projectName != new.projectName { changes.append("项目名称：\(old.projectName) → \(new.projectName)") }
        if old.projectBrief != new.projectBrief { changes.append("更新项目目标、资料或约束说明") }
        if old.projectDirectoryPath != new.projectDirectoryPath {
            let before = old.projectDirectoryPath.isEmpty ? "AiGo 托管目录" : old.projectDirectoryPath
            let after = new.projectDirectoryPath.isEmpty ? "AiGo 托管目录" : new.projectDirectoryPath
            changes.append("项目工作目录：\(before) → \(after)")
        }

        let oldProfiles = Dictionary(uniqueKeysWithValues: old.profiles.map { ($0.id, $0) })
        let newProfiles = Dictionary(uniqueKeysWithValues: new.profiles.map { ($0.id, $0) })
        if oldProfiles.keys != newProfiles.keys { changes.append("Codex CLI 配置数量：\(old.profiles.count) → \(new.profiles.count)") }
        for profile in new.profiles {
            if let previous = oldProfiles[profile.id], previous != profile {
                let beforeModel = previous.modelID.isEmpty ? "CLI 默认" : previous.modelID
                let afterModel = profile.modelID.isEmpty ? "CLI 默认" : profile.modelID
                changes.append("模型配置“\(profile.name)”：\(beforeModel)/\(previous.reasoningEffort.rawValue) → \(afterModel)/\(profile.reasoningEffort.rawValue)")
            }
        }

        let oldAgents = Dictionary(uniqueKeysWithValues: old.agents.map { ($0.id, $0) })
        let newAgents = Dictionary(uniqueKeysWithValues: new.agents.map { ($0.id, $0) })
        for agent in new.agents where oldAgents[agent.id] == nil { changes.append("新增智能体：\(agent.name)（\(agent.role.title)）") }
        for agent in old.agents where newAgents[agent.id] == nil { changes.append("移除智能体：\(agent.name)") }
        for agent in new.agents {
            if let previous = oldAgents[agent.id], previous != agent {
                changes.append("更新智能体：\(previous.name) → \(agent.name)，角色、模型或指令已同步")
            }
        }

        let oldStepIDs = old.steps.map(\.id)
        let newStepIDs = new.steps.map(\.id)
        if oldStepIDs != newStepIDs { changes.append("流程结构调整：\(old.steps.count) 步 → \(new.steps.count) 步") }
        let oldSteps = Dictionary(uniqueKeysWithValues: old.steps.map { ($0.id, $0) })
        for (index, step) in new.steps.enumerated() {
            if oldSteps[step.id] == nil {
                changes.append("新增第 \(index + 1) 步：\(step.title)")
            } else if oldSteps[step.id] != step {
                changes.append("更新第 \(index + 1) 步：\(step.title) 的执行者、输入或任务要求")
            }
        }

        guard !changes.isEmpty else { return nil }
        let clipped = Array(changes.prefix(20))
        let remaining = max(0, changes.count - clipped.count)
        let suffix = remaining > 0 ? "\n- 另有 \(remaining) 项同批变更" : ""
        return MemoryRecord(
            kind: .changeLog,
            title: "项目配置自动变更",
            content: clipped.map { "- \($0)" }.joined(separator: "\n") + suffix,
            source: "AiGo 变更检测"
        )
    }

    static func stepMemories(from execution: StepExecution, runID: UUID) -> [MemoryRecord] {
        let body = memorySection(in: execution.output)
        let candidates: [(kind: MemoryKind, key: String?, content: String)]
        if let body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            candidates = parseAtomicItems(from: body)
        } else {
            candidates = [(
                .stepInsight,
                nil,
                bounded(execution.output.trimmingCharacters(in: .whitespacesAndNewlines), limit: 1_200)
            )]
        }

        let model = execution.modelID ?? "CLI 默认模型"
        return candidates.prefix(maximumAtomicRecordsPerStep).compactMap { item in
            let content = bounded(item.content.trimmingCharacters(in: .whitespacesAndNewlines), limit: 900)
            guard !content.isEmpty else { return nil }
            let stableKey: String
            if let key = item.key, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                stableKey = "topic:\(normalizedKey(key))"
            } else {
                stableKey = "content:\(stableHash(normalizedContent(content)))"
            }
            let shortKey = item.key?.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = shortKey?.isEmpty == false ? shortKey! : String(content.prefix(30))
            return MemoryRecord(
                kind: item.kind,
                title: "步骤 \(execution.stepNumber) · \(item.kind.title) · \(detail)",
                content: content,
                source: "Codex CLI · \(execution.agentName) · \(model)/\(execution.reasoningEffort ?? "default")",
                relatedStepID: execution.stepID,
                relatedRunID: runID,
                stableKey: stableKey
            )
        }
    }

    static func runSummary(from session: RunSession) -> MemoryRecord {
        let visible = session.executions.prefix(60)
        var lines = visible.map { execution in
            let model = execution.modelID ?? "CLI 默认"
            return "- 步骤 \(execution.stepNumber)“\(execution.stepTitle)”：\(execution.status.rawValue)，\(execution.agentName)，\(model)/\(execution.reasoningEffort ?? "default")"
        }
        if session.executions.count > visible.count {
            lines.append("- 另有 \(session.executions.count - visible.count) 条执行记录，完整内容保存在 Run 归档中")
        }
        return MemoryRecord(
            kind: .runSummary,
            title: "运行 \(session.id.uuidString.prefix(8)) · \(session.phase.title)",
            content: lines.joined(separator: "\n"),
            source: "AiGo 编排器",
            relatedRunID: session.id
        )
    }

    static func selectMemories(
        from project: ProjectWorkspace,
        agent: AgentSeat,
        step: WorkflowStep,
        characterBudget: Int = promptCharacterBudget,
        recordLimit: Int = promptRecordLimit
    ) -> MemorySelection {
        let active = project.memories.filter { $0.isActive && $0.kind.participatesInPrompt }
        let mainline = active.first(where: { $0.kind == .mainline })
        let query = "\(project.projectName) \(agent.name) \(agent.role.title) \(agent.instruction) \(step.title) \(step.instruction)"
        let queryTerms = relevanceTerms(from: query)

        let candidates = active.enumerated()
            .filter { $0.element.kind != .mainline }
            .map { offset, record -> (record: MemoryRecord, score: Int) in
                let recordTerms = relevanceTerms(from: record.title + " " + record.content)
                let overlap = queryTerms.intersection(recordTerms).count
                let recency = max(0, 18 - min(offset, 18))
                return (record, record.kind.promptPriority + min(overlap, 12) * 9 + recency)
            }
            .sorted {
                if $0.score == $1.score { return $0.record.updatedAt > $1.record.updatedAt }
                return $0.score > $1.score
            }

        var selected: [MemoryRecord] = []
        var characters = 0
        if var mainline, recordLimit > 0, characterBudget > 0 {
            mainline.title = String(mainline.title.prefix(characterBudget))
            let remaining = max(0, characterBudget - mainline.title.count)
            mainline.content = String(mainline.content.prefix(remaining))
            characters = mainline.title.count + mainline.content.count
            selected.append(mainline)
        }

        for candidate in candidates {
            guard selected.count < recordLimit else { break }
            let size = candidate.record.title.count + candidate.record.content.count
            guard characters + size <= characterBudget else { continue }
            selected.append(candidate.record)
            characters += size
        }

        return MemorySelection(
            records: selected,
            eligibleCount: active.count,
            omittedCount: max(0, active.count - selected.count),
            characterCount: characters
        )
    }

    static func memoriesForPrompt(from project: ProjectWorkspace) -> [MemoryRecord] {
        guard let step = project.steps.first,
              let agent = project.agents.first(where: { $0.id == step.agentID }) else { return [] }
        return selectMemories(from: project, agent: agent, step: step).records
    }

    static func upserting(_ incoming: MemoryRecord, into project: ProjectWorkspace) -> MemoryUpsertResult {
        var updated = project
        var resolved = incoming
        if let stableKey = incoming.stableKey,
           let index = updated.memories.firstIndex(where: { $0.stableKey == stableKey }) {
            let previous = updated.memories[index]
            resolved.id = previous.id
            resolved.createdAt = previous.createdAt
            resolved.revision = previous.revision + (previous.content == incoming.content && previous.kind == incoming.kind ? 0 : 1)
            resolved.updatedAt = Date()
            updated.memories.remove(at: index)
        }
        updated.memories.append(resolved)
        updated = compacted(updated)
        if let stored = updated.memories.first(where: { $0.id == resolved.id }) { resolved = stored }
        return MemoryUpsertResult(project: updated, record: resolved)
    }

    static func appending(_ record: MemoryRecord, to project: ProjectWorkspace) -> ProjectWorkspace {
        upserting(record, into: project).project
    }

    static func compactHandoff(from output: String, limit: Int) -> String {
        if let section = memorySection(in: output), !section.isEmpty {
            return bounded(section, limit: limit)
        }
        return bounded(output.trimmingCharacters(in: .whitespacesAndNewlines), limit: limit)
    }

    static func mainlineContent(for project: ProjectWorkspace) -> String {
        let profileByID = Dictionary(uniqueKeysWithValues: project.profiles.map { ($0.id, $0) })
        let agentLines = project.agents.map { agent -> String in
            let profile = profileByID[agent.profileID]
            let model = profile?.modelID.isEmpty == false ? profile!.modelID : "跟随 CLI 默认模型"
            return "- \(agent.name)｜\(agent.role.title)｜\(model)｜\(profile?.reasoningEffort.rawValue ?? "default")"
        }.joined(separator: "\n")
        let agentByID = Dictionary(uniqueKeysWithValues: project.agents.map { ($0.id, $0) })
        let allSteps = project.steps.enumerated().map { index, step in
            "\(index + 1). \(step.title) → \(agentByID[step.agentID]?.name ?? "未分配")\(step.requiresApproval ? " [人工门控]" : "")"
        }.joined(separator: "\n")
        let stepLines = bounded(allSteps, limit: 2_400)
        let brief = bounded(project.projectBrief, limit: 1_600)
        let directory = project.projectDirectoryPath.isEmpty ? "AiGo 项目托管目录" : project.projectDirectoryPath

        return """
        # 项目主脉络

        项目：\(project.projectName)
        工作目录：\(directory)

        ## 研究目标与边界
        \(brief)

        ## 角色与本机 Codex CLI 模型
        \(agentLines.isEmpty ? "（暂无角色）" : agentLines)

        ## 当前编排顺序
        \(stepLines.isEmpty ? "（暂无步骤）" : stepLines)

        ## 共享原则
        后续角色只接收固定预算内、与当前任务相关的细粒度知识。修改日志和运行摘要仅供审计，不注入模型上下文。
        """
    }

    private static func memorySection(in output: String) -> String? {
        let lines = output.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var collecting = false
        var result: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !collecting {
                if trimmed.localizedCaseInsensitiveContains("共享记忆更新") {
                    collecting = true
                }
                continue
            }
            if trimmed.hasPrefix("#"), !trimmed.localizedCaseInsensitiveContains("共享记忆更新") { break }
            if trimmed.uppercased().hasPrefix("VERDICT:") { break }
            result.append(line)
        }
        let body = result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return collecting ? body : nil
    }

    private static func parseAtomicItems(from section: String) -> [(kind: MemoryKind, key: String?, content: String)] {
        let lines = section.components(separatedBy: "\n")
        var rawItems: [String] = []
        var current = ""

        func flush() {
            let value = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { rawItems.append(value) }
            current = ""
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                flush()
                continue
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                flush()
                current = String(trimmed.dropFirst(2))
            } else if current.isEmpty {
                current = trimmed
            } else {
                current += " " + trimmed
            }
        }
        flush()

        return rawItems.prefix(maximumAtomicRecordsPerStep).map { raw in
            var content = raw
            var key: String?
            var kind: MemoryKind = .stepInsight

            if content.hasPrefix("["), let end = content.firstIndex(of: "]") {
                let header = String(content[content.index(after: content.startIndex)..<end])
                let parts = header.split(separator: "|", maxSplits: 1).map(String.init)
                kind = memoryKind(from: parts.first ?? "")
                if parts.count > 1 { key = parts[1] }
                content = String(content[content.index(after: end)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else if let separator = content.firstIndex(where: { $0 == ":" || $0 == "：" }) {
                let prefix = String(content[..<separator])
                if prefix.count <= 12, let classified = classifiedKind(from: prefix) {
                    kind = classified
                    content = String(content[content.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            return (kind, key, content)
        }
    }

    private static func memoryKind(from label: String) -> MemoryKind {
        classifiedKind(from: label) ?? .stepInsight
    }

    private static func classifiedKind(from label: String) -> MemoryKind? {
        let value = label.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if value.contains("决策") || value.contains("decision") { return .decision }
        if value.contains("约束") || value.contains("constraint") || value.contains("boundary") { return .constraint }
        if value.contains("风险") || value.contains("未知") || value.contains("risk") || value.contains("unknown") { return .risk }
        if value.contains("后续") || value.contains("待办") || value.contains("next") || value.contains("action") { return .nextAction }
        if value.contains("结论") || value.contains("事实") || value.contains("发现") || value.contains("证据") || value.contains("finding") || value.contains("fact") || value.contains("evidence") { return .finding }
        if value.contains("成果") || value.contains("insight") { return .stepInsight }
        return nil
    }

    private static func compacted(_ project: ProjectWorkspace) -> ProjectWorkspace {
        var updated = project
        let mainline = updated.memories
            .filter { $0.kind == .mainline }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(1)
        let knowledge = updated.memories
            .filter { $0.kind != .mainline && !$0.kind.isAudit }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(WorkspaceRules.maxPersistentKnowledgeMemories)
        let audit = updated.memories
            .filter { $0.kind.isAudit }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(WorkspaceRules.maxPersistentAuditMemories)
        updated.memories = Array(mainline) + Array(knowledge) + Array(audit)
        return updated
    }

    private static func relevanceTerms(from text: String) -> Set<String> {
        let lowered = text.lowercased()
        let words = lowered.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
        let compact = lowered.filter { $0.isLetter || $0.isNumber }
        let characters = Array(compact.prefix(1_500))
        var terms = Set(words.prefix(160))
        if characters.count >= 2 {
            for index in 0..<(characters.count - 1) {
                terms.insert(String(characters[index...index + 1]))
            }
        }
        return terms
    }

    private static func normalizedKey(_ value: String) -> String {
        let lowered = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        var result = ""
        var pendingSeparator = false
        for character in lowered {
            if character.isLetter || character.isNumber {
                if pendingSeparator, !result.isEmpty { result.append("-") }
                result.append(character)
                pendingSeparator = false
            } else {
                pendingSeparator = true
            }
            if result.count >= 96 { break }
        }
        return result.isEmpty ? stableHash(lowered) : result
    }

    private static func normalizedContent(_ value: String) -> String {
        value.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private static func bounded(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        return String(value.prefix(max(0, limit - 18))) + "\n…（已按预算截断）"
    }
}
