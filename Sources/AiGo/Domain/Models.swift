import Foundation

enum AgentRole: String, CaseIterable, Codable, Identifiable, Hashable {
    case architect, collector, methodologist, coder, analyst, reviewer, writer, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .architect: return "总体设计师"
        case .collector: return "信息收集员"
        case .methodologist: return "方法学专家"
        case .coder: return "代码编写员"
        case .analyst: return "数据分析员"
        case .reviewer: return "审核员"
        case .writer: return "科研写作员"
        case .custom: return "自定义角色"
        }
    }

    var symbol: String {
        switch self {
        case .architect: return "point.3.connected.trianglepath.dotted"
        case .collector: return "books.vertical.fill"
        case .methodologist: return "function"
        case .coder: return "chevron.left.forwardslash.chevron.right"
        case .analyst: return "chart.xyaxis.line"
        case .reviewer: return "checkmark.seal.fill"
        case .writer: return "doc.text.fill"
        case .custom: return "person.crop.circle.badge.plus"
        }
    }

    var defaultInstruction: String {
        switch self {
        case .architect:
            return "拆解科研目标，建立可验证的主脉络、任务边界、交付物、依赖关系和验收标准。"
        case .collector:
            return "整理背景、证据线索、检索策略、冲突结论和待核验事实；明确区分证据、推断与未知。"
        case .methodologist:
            return "设计变量、数据、实验或分析方法，检查混杂因素、统计有效性、复现要求和失效条件。"
        case .coder:
            return "把已确定的方法转化为模块化实现方案或代码，说明接口、错误边界、测试和运行假设。"
        case .analyst:
            return "解释数据、比较方案、量化不确定性，并输出可追踪、可复核的分析过程。"
        case .reviewer:
            return "独立审核上游产物并逐项对照验收标准；最后一行严格输出 VERDICT: PASS 或 VERDICT: FAIL。"
        case .writer:
            return "将已审核内容组织成结构严谨、事实边界清楚、限制完整的科研文稿。"
        case .custom:
            return "明确该角色的职责、输入、输出、禁止事项和完成判据。"
        }
    }

    var tintHex: String {
        switch self {
        case .architect: return "6E7BFF"
        case .collector: return "38BDF8"
        case .methodologist: return "14B8A6"
        case .coder: return "A78BFA"
        case .analyst: return "F59E0B"
        case .reviewer: return "F43F5E"
        case .writer: return "22C55E"
        case .custom: return "94A3B8"
        }
    }
}

enum ReasoningEffort: String, CaseIterable, Codable, Identifiable, Hashable {
    case none, low, medium, high, xhigh, max, ultra

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "无额外推理"
        case .low: return "快速"
        case .medium: return "标准"
        case .high: return "深度"
        case .xhigh: return "极深"
        case .max: return "最大"
        case .ultra: return "Ultra"
        }
    }
}

struct CLIModelDescriptor: Identifiable, Codable, Hashable {
    var modelID: String
    var displayName: String
    var defaultReasoningEffort: ReasoningEffort
    var supportedReasoningEfforts: [ReasoningEffort]
    var isDefault: Bool
    var priority: Int

    var id: String { modelID }
}

struct CodexProfile: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var modelID: String
    var reasoningEffort: ReasoningEffort

    init(
        id: UUID = UUID(),
        name: String,
        modelID: String = "",
        reasoningEffort: ReasoningEffort
    ) {
        self.id = id
        self.name = name
        self.modelID = modelID
        self.reasoningEffort = reasoningEffort
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, modelID, reasoningEffort
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Codex CLI 配置"
        modelID = try container.decodeIfPresent(String.self, forKey: .modelID) ?? ""
        reasoningEffort = try container.decodeIfPresent(ReasoningEffort.self, forKey: .reasoningEffort) ?? .medium
    }
}

struct CodexCLISettings: Codable, Hashable {
    var executablePath: String
    var cachedModels: [CLIModelDescriptor]
    var cliVersion: String?
    var loginSummary: String?
    var lastRefreshedAt: Date?

    static func starter() -> CodexCLISettings {
        let candidates = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/usr/bin/codex"
        ]
        let detected = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) ?? "codex"
        return CodexCLISettings(
            executablePath: detected,
            cachedModels: [],
            cliVersion: nil,
            loginSummary: nil,
            lastRefreshedAt: nil
        )
    }
}

struct AgentSeat: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var role: AgentRole
    var instruction: String
    var profileID: UUID
    var colorHex: String

    init(
        id: UUID = UUID(),
        name: String,
        role: AgentRole,
        instruction: String? = nil,
        profileID: UUID,
        colorHex: String? = nil
    ) {
        self.id = id
        self.name = name
        self.role = role
        self.instruction = instruction ?? role.defaultInstruction
        self.profileID = profileID
        self.colorHex = colorHex ?? role.tintHex
    }
}

enum StepInputMode: String, CaseIterable, Codable, Identifiable, Hashable {
    case previous, accumulated
    var id: String { rawValue }
    var title: String { self == .previous ? "仅上一步产物" : "压缩累计产物" }
}

struct WorkflowStep: Identifiable, Codable, Hashable {
    var id: UUID
    var title: String
    var instruction: String
    var agentID: UUID
    var inputMode: StepInputMode
    var requiresApproval: Bool
    var reviewReturnStepID: UUID?

    init(
        id: UUID = UUID(),
        title: String,
        instruction: String,
        agentID: UUID,
        inputMode: StepInputMode = .accumulated,
        requiresApproval: Bool = false,
        reviewReturnStepID: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.instruction = instruction
        self.agentID = agentID
        self.inputMode = inputMode
        self.requiresApproval = requiresApproval
        self.reviewReturnStepID = reviewReturnStepID
    }
}

enum MemoryKind: String, CaseIterable, Codable, Identifiable, Hashable {
    case mainline, finding, decision, constraint, risk, nextAction, stepInsight
    case changeLog, runSummary, migrated
    var id: String { rawValue }

    var title: String {
        switch self {
        case .mainline: return "主脉络"
        case .finding: return "事实与发现"
        case .constraint: return "约束条件"
        case .nextAction: return "后续行动"
        case .changeLog: return "修改日志"
        case .stepInsight: return "步骤成果"
        case .decision: return "关键决策"
        case .risk: return "风险与未知"
        case .runSummary: return "运行摘要"
        case .migrated: return "迁移记忆"
        }
    }

    var symbol: String {
        switch self {
        case .mainline: return "point.3.filled.connected.trianglepath.dotted"
        case .finding: return "text.magnifyingglass"
        case .constraint: return "lock.shield.fill"
        case .nextAction: return "arrow.forward.square.fill"
        case .changeLog: return "clock.arrow.circlepath"
        case .stepInsight: return "lightbulb.max.fill"
        case .decision: return "checkmark.diamond.fill"
        case .risk: return "exclamationmark.triangle.fill"
        case .runSummary: return "list.clipboard.fill"
        case .migrated: return "archivebox.fill"
        }
    }

    var participatesInPrompt: Bool {
        switch self {
        case .changeLog, .runSummary: return false
        default: return true
        }
    }

    var isAudit: Bool { self == .changeLog || self == .runSummary }

    var promptPriority: Int {
        switch self {
        case .mainline: return 1_000
        case .constraint: return 90
        case .decision: return 82
        case .risk: return 78
        case .finding: return 68
        case .nextAction: return 56
        case .stepInsight: return 38
        case .migrated: return 24
        case .changeLog, .runSummary: return 0
        }
    }
}

struct MemoryRecord: Identifiable, Codable, Hashable {
    var id: UUID
    var kind: MemoryKind
    var title: String
    var content: String
    var source: String
    var relatedStepID: UUID?
    var relatedRunID: UUID?
    var isActive: Bool
    var isAutoGenerated: Bool
    var stableKey: String?
    var revision: Int
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        kind: MemoryKind,
        title: String,
        content: String,
        source: String = "AiGo 自动记忆",
        relatedStepID: UUID? = nil,
        relatedRunID: UUID? = nil,
        isActive: Bool = true,
        isAutoGenerated: Bool = true,
        stableKey: String? = nil,
        revision: Int = 1,
        createdAt: Date = Date(),
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.content = content
        self.source = source
        self.relatedStepID = relatedStepID
        self.relatedRunID = relatedRunID
        self.isActive = isActive
        self.isAutoGenerated = isAutoGenerated
        self.stableKey = stableKey
        self.revision = revision
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, title, content, source, relatedStepID, relatedRunID
        case isActive, isAutoGenerated, stableKey, revision, createdAt, updatedAt
    }

    private enum LegacyCodingKeys: String, CodingKey { case isApproved }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try container.decodeIfPresent(MemoryKind.self, forKey: .kind) ?? .migrated
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? "迁移记忆"
        content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
        source = try container.decodeIfPresent(String.self, forKey: .source) ?? "0.1.0 数据迁移"
        relatedStepID = try container.decodeIfPresent(UUID.self, forKey: .relatedStepID)
        relatedRunID = try container.decodeIfPresent(UUID.self, forKey: .relatedRunID)
        let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
        isActive = try container.decodeIfPresent(Bool.self, forKey: .isActive)
            ?? legacy.decodeIfPresent(Bool.self, forKey: .isApproved)
            ?? true
        isAutoGenerated = try container.decodeIfPresent(Bool.self, forKey: .isAutoGenerated) ?? false
        stableKey = try container.decodeIfPresent(String.self, forKey: .stableKey)
        revision = try container.decodeIfPresent(Int.self, forKey: .revision) ?? 1
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }
}

enum RunPhase: String, Codable, Hashable {
    case idle, running, awaitingApproval, completed, failed, cancelled
    var title: String {
        switch self {
        case .idle: return "待运行"
        case .running: return "运行中"
        case .awaitingApproval: return "等待批准"
        case .completed: return "已完成"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        }
    }
}

enum StepRunStatus: String, Codable, Hashable { case queued, running, completed, failed, cancelled }

struct StepExecution: Identifiable, Codable, Hashable {
    var id: UUID
    var stepID: UUID
    var stepNumber: Int
    var stepTitle: String
    var agentName: String
    var attempt: Int
    var status: StepRunStatus
    var output: String
    var contextPreview: String
    var inputTokens: Int?
    var outputTokens: Int?
    var startedAt: Date
    var completedAt: Date?
    var errorMessage: String?
    var modelID: String?
    var reasoningEffort: String?
    var cliThreadID: String?
    var activityLog: [String]?

    init(
        id: UUID = UUID(),
        stepID: UUID,
        stepNumber: Int,
        stepTitle: String,
        agentName: String,
        attempt: Int,
        contextPreview: String,
        modelID: String?,
        reasoningEffort: String,
        startedAt: Date = Date()
    ) {
        self.id = id
        self.stepID = stepID
        self.stepNumber = stepNumber
        self.stepTitle = stepTitle
        self.agentName = agentName
        self.attempt = attempt
        self.status = .running
        self.output = ""
        self.contextPreview = contextPreview
        self.inputTokens = nil
        self.outputTokens = nil
        self.startedAt = startedAt
        self.completedAt = nil
        self.errorMessage = nil
        self.modelID = modelID
        self.reasoningEffort = reasoningEffort
        self.cliThreadID = nil
        self.activityLog = []
    }
}

struct RunEvent: Identifiable, Codable, Hashable {
    var id: UUID
    var timestamp: Date
    var message: String
    var kind: String
    init(id: UUID = UUID(), timestamp: Date = Date(), message: String, kind: String = "info") {
        self.id = id
        self.timestamp = timestamp
        self.message = message
        self.kind = kind
    }
}

struct RunSession: Identifiable, Codable, Hashable {
    var id: UUID
    var phase: RunPhase
    var startedAt: Date?
    var completedAt: Date?
    var currentStepIndex: Int?
    var executions: [StepExecution]
    var events: [RunEvent]
    var errorMessage: String?
    var projectID: UUID?

    static var idle: RunSession {
        RunSession(id: UUID(), phase: .idle, startedAt: nil, completedAt: nil, currentStepIndex: nil, executions: [], events: [], errorMessage: nil, projectID: nil)
    }
}

struct ProjectWorkspace: Codable, Hashable, Identifiable {
    var id: UUID
    var schemaVersion: Int
    var projectName: String
    var projectBrief: String
    var projectDirectoryPath: String
    var profiles: [CodexProfile]
    var agents: [AgentSeat]
    var steps: [WorkflowStep]
    var memories: [MemoryRecord]
    var runHistory: [RunSession]
    var cliSettings: CodexCLISettings
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID,
        schemaVersion: Int,
        projectName: String,
        projectBrief: String,
        projectDirectoryPath: String,
        profiles: [CodexProfile],
        agents: [AgentSeat],
        steps: [WorkflowStep],
        memories: [MemoryRecord],
        runHistory: [RunSession],
        cliSettings: CodexCLISettings,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.projectName = projectName
        self.projectBrief = projectBrief
        self.projectDirectoryPath = projectDirectoryPath
        self.profiles = profiles
        self.agents = agents
        self.steps = steps
        self.memories = memories
        self.runHistory = runHistory
        self.cliSettings = cliSettings
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    static func starter(name: String = "未命名科研项目") -> ProjectWorkspace {
        let fast = CodexProfile(name: "CLI 快速", reasoningEffort: .low)
        let standard = CodexProfile(name: "CLI 标准", reasoningEffort: .medium)
        let deep = CodexProfile(name: "CLI 深度", reasoningEffort: .high)
        let audit = CodexProfile(name: "CLI 审核", reasoningEffort: .xhigh)

        let architect = AgentSeat(name: "总体设计师", role: .architect, profileID: deep.id)
        let collector = AgentSeat(name: "信息收集员", role: .collector, profileID: standard.id)
        let methodologist = AgentSeat(name: "方法学专家", role: .methodologist, profileID: deep.id)
        let coder = AgentSeat(name: "代码编写员", role: .coder, profileID: standard.id)
        let reviewer = AgentSeat(name: "审核员", role: .reviewer, profileID: audit.id)
        let writer = AgentSeat(name: "科研写作员", role: .writer, profileID: deep.id)

        let design = WorkflowStep(title: "建立研究蓝图", instruction: "拆解研究问题、假设、交付物、验收标准和风险。", agentID: architect.id, requiresApproval: true)
        let evidence = WorkflowStep(title: "整理证据与资料", instruction: "制定检索策略，整理证据、冲突结论和证据缺口；不得虚构引用。", agentID: collector.id)
        let method = WorkflowStep(title: "形成研究方法", instruction: "定义数据、变量、实验或分析方法、对照、评价指标与复现要求。", agentID: methodologist.id)
        let implementation = WorkflowStep(title: "给出实现方案", instruction: "把方法转成模块、接口、伪代码或代码，并给出测试与失败处理。", agentID: coder.id)
        let review = WorkflowStep(title: "独立质量审核", instruction: "检查证据、方法、实现与复现性；最后一行只写 VERDICT: PASS 或 VERDICT: FAIL。", agentID: reviewer.id, reviewReturnStepID: method.id)
        let writing = WorkflowStep(title: "汇总科研报告", instruction: "只使用通过审核的内容形成科研报告，保留限制、风险和待核验项。", agentID: writer.id)

        let now = Date()
        let projectID = UUID()
        return ProjectWorkspace(
            id: projectID,
            schemaVersion: 3,
            projectName: name,
            projectBrief: "在这里写清研究目标、对象、可用资料、约束条件和期望交付物。",
            projectDirectoryPath: "",
            profiles: [fast, standard, deep, audit],
            agents: [architect, collector, methodologist, coder, reviewer, writer],
            steps: [design, evidence, method, implementation, review, writing],
            memories: [],
            runHistory: [],
            cliSettings: .starter(),
            createdAt: now,
            updatedAt: now
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, schemaVersion, projectName, projectBrief, projectDirectoryPath, profiles, agents, steps, memories
        case runHistory, cliSettings, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        schemaVersion = 3
        projectName = try container.decodeIfPresent(String.self, forKey: .projectName) ?? "迁移项目"
        projectBrief = try container.decodeIfPresent(String.self, forKey: .projectBrief) ?? ""
        projectDirectoryPath = try container.decodeIfPresent(String.self, forKey: .projectDirectoryPath) ?? ""
        profiles = try container.decodeIfPresent([CodexProfile].self, forKey: .profiles) ?? []
        agents = try container.decodeIfPresent([AgentSeat].self, forKey: .agents) ?? []
        steps = try container.decodeIfPresent([WorkflowStep].self, forKey: .steps) ?? []
        memories = try container.decodeIfPresent([MemoryRecord].self, forKey: .memories) ?? []
        runHistory = try container.decodeIfPresent([RunSession].self, forKey: .runHistory) ?? []
        cliSettings = try container.decodeIfPresent(CodexCLISettings.self, forKey: .cliSettings) ?? .starter()
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    mutating func sanitize() {
        schemaVersion = 3
        projectDirectoryPath = projectDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        agents = Array(agents.prefix(WorkspaceRules.maxAgents))
        if profiles.isEmpty { profiles = [CodexProfile(name: "CLI 默认", reasoningEffort: .medium)] }
        let profileIDs = Set(profiles.map(\.id))
        for index in agents.indices where !profileIDs.contains(agents[index].profileID) {
            agents[index].profileID = profiles[0].id
        }
        let agentIDs = Set(agents.map(\.id))
        if let fallback = agents.first?.id {
            for index in steps.indices where !agentIDs.contains(steps[index].agentID) { steps[index].agentID = fallback }
        } else {
            steps = []
        }
        let stepIDs = Set(steps.map(\.id))
        for index in steps.indices {
            if let target = steps[index].reviewReturnStepID,
               target == steps[index].id || !stepIDs.contains(target) {
                steps[index].reviewReturnStepID = nil
            }
        }
        runHistory = Array(runHistory.prefix(20))
        let mainline = memories
            .filter { $0.kind == .mainline }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(1)
        let knowledge = memories
            .filter { $0.kind != .mainline && !$0.kind.isAudit }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(WorkspaceRules.maxPersistentKnowledgeMemories)
        let audit = memories
            .filter { $0.kind.isAudit }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(WorkspaceRules.maxPersistentAuditMemories)
        memories = Array(mainline) + Array(knowledge) + Array(audit)
        updatedAt = Date()
    }
}

struct WorkspaceLibrary: Codable, Hashable {
    var schemaVersion: Int
    var selectedProjectID: UUID
    var projects: [ProjectWorkspace]
    var updatedAt: Date

    static func starter() -> WorkspaceLibrary {
        let project = ProjectWorkspace.starter()
        return WorkspaceLibrary(schemaVersion: 3, selectedProjectID: project.id, projects: [project], updatedAt: Date())
    }

    mutating func sanitize() {
        schemaVersion = 3
        if projects.isEmpty { projects = [.starter()] }
        for index in projects.indices { projects[index].sanitize() }
        if !projects.contains(where: { $0.id == selectedProjectID }) { selectedProjectID = projects[0].id }
        updatedAt = Date()
    }
}

enum WorkspaceRules {
    static let maxAgents = 8
    static let maxPersistentKnowledgeMemories = 120
    static let maxPersistentAuditMemories = 60
    static func canAddAgent(to workspace: ProjectWorkspace) -> Bool { workspace.agents.count < maxAgents && !workspace.profiles.isEmpty }
    static func validationMessage(for workspace: ProjectWorkspace) -> String? {
        if workspace.agents.isEmpty { return "至少需要一个智能体。" }
        if workspace.agents.count > maxAgents { return "智能体最多只能有 8 个。" }
        if workspace.steps.isEmpty { return "至少需要一个流程步骤。" }
        if workspace.projectBrief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请先填写项目目标。" }
        let agentIDs = Set(workspace.agents.map(\.id))
        if workspace.steps.contains(where: { !agentIDs.contains($0.agentID) }) { return "流程中存在未分配智能体的步骤。" }
        return nil
    }
}

enum AppSection: String, CaseIterable, Identifiable {
    case blueprint, run, memory, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .blueprint: return "编排蓝图"
        case .run: return "运行监控"
        case .memory: return "共享记忆"
        case .settings: return "Codex 设置"
        }
    }
    var symbol: String {
        switch self {
        case .blueprint: return "point.3.filled.connected.trianglepath.dotted"
        case .run: return "play.circle.fill"
        case .memory: return "brain.head.profile.fill"
        case .settings: return "slider.horizontal.3"
        }
    }
}
