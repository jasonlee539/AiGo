import Foundation
import SwiftUI

@MainActor
final class WorkspaceStore: ObservableObject {
    @Published private(set) var library: WorkspaceLibrary
    @Published var workspace: ProjectWorkspace {
        didSet {
            guard isReady, !isInternalMutation else { return }
            syncWorkspaceIntoLibrary()
            scheduleAutomaticMemory(from: oldValue)
            persist()
        }
    }
    @Published var selectedSection: AppSection = .blueprint
    @Published var selectedAgentID: UUID?
    @Published var selectedStepID: UUID?
    @Published var selectedMemoryID: UUID?
    @Published var persistenceMessage: String?
    @Published var migrationMessage: String?
    @Published var isRefreshingCLI = false
    @Published var cliMessage: String?
    @Published private(set) var recoverableRunCheckpoint: RunCheckpoint? = nil

    let storageURL: URL
    private var isReady = false
    private var isInternalMutation = false
    private var automaticMemoryBaseline: ProjectWorkspace?
    private var automaticMemoryTask: Task<Void, Never>?
    private var checkpointWriteTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingRunCheckpoints: [UUID: RunCheckpoint] = [:]
    private var runMemoryBaselines: [UUID: RunMemoryBaseline] = [:]
    private let persistenceQueue = DispatchQueue(label: "cc.aigo.persistence", qos: .utility)
    private var persistenceRevision = 0

    var projects: [ProjectWorkspace] { library.projects }

    init(storageURL: URL? = nil) {
        self.storageURL = storageURL ?? Self.defaultStorageURL()
        let legacyBackupMessage = Self.backUpLegacyWorkspaceIfNeeded(at: self.storageURL)
        var loaded = Self.loadLibrary(from: self.storageURL) ?? .starter()
        let sourceSchemaVersion = loaded.schemaVersion
        loaded.sanitize()
        var legacyRestartResidueCount = 0
        for index in loaded.projects.indices {
            let cleanup = Self.removingLegacyRestartMemoryResidue(from: loaded.projects[index])
            loaded.projects[index] = cleanup.project
            legacyRestartResidueCount += cleanup.removedCount
        }
        let selected = loaded.projects.first(where: { $0.id == loaded.selectedProjectID }) ?? loaded.projects[0]
        let synchronized = AutomaticMemoryService.synchronizeMainline(in: selected)
        if let index = loaded.projects.firstIndex(where: { $0.id == selected.id }) { loaded.projects[index] = synchronized }
        let legacyCheckpoints = loaded.projects.compactMap {
            Self.legacyInterruptedCheckpoint(in: $0, sourceSchemaVersion: sourceSchemaVersion)
        }
        self.library = loaded
        self.workspace = synchronized
        self.selectedAgentID = synchronized.agents.first?.id
        self.selectedStepID = synchronized.steps.first?.id
        self.selectedMemoryID = synchronized.memories.first?.id
        let residueMessage = legacyRestartResidueCount > 0
            ? "已清理旧版“重新开始”遗留的 \(legacyRestartResidueCount) 条运行记忆。"
            : nil
        self.migrationMessage = [legacyBackupMessage, residueMessage]
            .compactMap { $0 }
            .joined(separator: "\n")
        if self.migrationMessage?.isEmpty == true { self.migrationMessage = nil }
        let storedCheckpoint = Self.loadRunCheckpoint(
            projectID: synchronized.id,
            storageURL: self.storageURL
        )
        let migratedCheckpoint = storedCheckpoint == nil
            ? legacyCheckpoints.first(where: { $0.projectID == synchronized.id })
            : nil
        self.recoverableRunCheckpoint = storedCheckpoint ?? migratedCheckpoint
        if let checkpoint = self.recoverableRunCheckpoint {
            self.pendingRunCheckpoints[checkpoint.projectID] = checkpoint
        }
        self.isReady = true
        persist()
        for checkpoint in legacyCheckpoints where Self.loadRunCheckpoint(
            projectID: checkpoint.projectID,
            storageURL: self.storageURL
        ) == nil {
            persistRunCheckpoint(checkpoint)
        }
    }

    deinit {
        automaticMemoryTask?.cancel()
        checkpointWriteTasks.values.forEach { $0.cancel() }
    }

    static func defaultStorageURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("AiGo", isDirectory: true).appendingPathComponent("workspace.json")
    }

    private static func loadLibrary(from url: URL) -> WorkspaceLibrary? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let library = try? decoder.decode(WorkspaceLibrary.self, from: data) { return library }
        if var legacyProject = try? decoder.decode(ProjectWorkspace.self, from: data) {
            legacyProject.sanitize()
            legacyProject = AutomaticMemoryService.synchronizeMainline(in: legacyProject)
            return WorkspaceLibrary(schemaVersion: 5, selectedProjectID: legacyProject.id, projects: [legacyProject], updatedAt: Date())
        }
        return nil
    }

    private static func backUpLegacyWorkspaceIfNeeded(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard (try? decoder.decode(WorkspaceLibrary.self, from: data)) == nil,
              (try? decoder.decode(ProjectWorkspace.self, from: data)) != nil else { return nil }

        let backup = url.deletingLastPathComponent().appendingPathComponent("workspace-v0.1.0-backup.json")
        do {
            if !FileManager.default.fileExists(atPath: backup.path) {
                try FileManager.default.copyItem(at: url, to: backup)
            }
            return "已将 0.1.0 工作区备份到：\(backup.path)"
        } catch {
            return "旧工作区已迁移，但备份失败：\(error.localizedDescription)"
        }
    }

    private static func removingLegacyRestartMemoryResidue(
        from source: ProjectWorkspace
    ) -> (project: ProjectWorkspace, removedCount: Int) {
        let restartedRunIDs = Set(source.runHistory.compactMap { session -> UUID? in
            guard session.phase == .cancelled,
                  session.events.contains(where: {
                      $0.message.contains("用户选择重新开始")
                          || $0.message.contains("回滚本次并重新运行")
                  }) else { return nil }
            return session.id
        })
        guard !restartedRunIDs.isEmpty else { return (source, 0) }

        var project = source
        let originalCount = project.memories.count
        project.memories.removeAll { memory in
            memory.relatedRunID.map(restartedRunIDs.contains) == true
        }
        let removedCount = originalCount - project.memories.count
        if removedCount > 0 {
            project = AutomaticMemoryService.synchronizeMainline(in: project)
        }
        return (project, removedCount)
    }

    func persist() {
        syncWorkspaceIntoLibrary()
        library.updatedAt = Date()
        enqueueLibraryPersistence(library)
    }

    /// Waits for all workspace/checkpoint transactions already submitted to the
    /// serial persistence lane. Production UI never blocks on this; tests and
    /// orderly hand-off points can explicitly await durability.
    func flushPersistence() async {
        await withCheckedContinuation { continuation in
            persistenceQueue.async {
                continuation.resume()
            }
        }
    }

    func selectProject(_ id: UUID) {
        guard id != workspace.id, let target = library.projects.first(where: { $0.id == id }) else { return }
        commitAutomaticMemoryNow()
        library.selectedProjectID = id
        setWorkspaceInternally(AutomaticMemoryService.synchronizeMainline(in: target))
        selectedAgentID = workspace.agents.first?.id
        selectedStepID = workspace.steps.first?.id
        selectedMemoryID = workspace.memories.first?.id
        selectedSection = .blueprint
        loadRunCheckpointForSelectedProject()
    }

    func addProject() {
        commitAutomaticMemoryNow()
        var project = ProjectWorkspace.starter(name: "科研项目 \(library.projects.count + 1)")
        project.cliSettings = workspace.cliSettings
        project = AutomaticMemoryService.synchronizeMainline(in: project)
        library.projects.append(project)
        library.selectedProjectID = project.id
        setWorkspaceInternally(project)
        selectedAgentID = project.agents.first?.id
        selectedStepID = project.steps.first?.id
        selectedMemoryID = project.memories.first?.id
        selectedSection = .blueprint
        loadRunCheckpointForSelectedProject()
    }

    func duplicateCurrentProject() {
        commitAutomaticMemoryNow()
        var copy = workspace
        copy.id = UUID()
        copy.projectName += " 副本"
        copy.projectDirectoryPath = ""
        copy.runHistory = []
        copy.memories = []
        copy.createdAt = Date()
        copy.updatedAt = Date()
        copy = AutomaticMemoryService.synchronizeMainline(in: copy)
        library.projects.append(copy)
        library.selectedProjectID = copy.id
        setWorkspaceInternally(copy)
        selectedMemoryID = copy.memories.first?.id
        selectedSection = .blueprint
        loadRunCheckpointForSelectedProject()
    }

    func deleteCurrentProject() {
        guard library.projects.count > 1,
              let index = library.projects.firstIndex(where: { $0.id == workspace.id }) else { return }
        let deletedProjectID = workspace.id
        automaticMemoryTask?.cancel()
        automaticMemoryBaseline = nil
        clearRunCheckpoint(projectID: deletedProjectID)
        clearRunMemoryBaseline(projectID: deletedProjectID)
        library.projects.remove(at: index)
        let next = library.projects[min(index, library.projects.count - 1)]
        library.selectedProjectID = next.id
        setWorkspaceInternally(next)
        selectedAgentID = next.agents.first?.id
        selectedStepID = next.steps.first?.id
        selectedMemoryID = next.memories.first?.id
        loadRunCheckpointForSelectedProject()
    }

    @discardableResult
    func addAgent() -> Bool {
        guard WorkspaceRules.canAddAgent(to: workspace), let profile = workspace.profiles.first else { return false }
        let agent = AgentSeat(name: "科研角色 \(workspace.agents.count + 1)", role: .custom, profileID: profile.id)
        workspace.agents.append(agent)
        selectedAgentID = agent.id
        selectedStepID = nil
        return true
    }

    func deleteAgent(id: UUID) {
        guard workspace.agents.count > 1, let index = workspace.agents.firstIndex(where: { $0.id == id }) else { return }
        workspace.agents.remove(at: index)
        guard let fallback = workspace.agents.first else { return }
        for stepIndex in workspace.steps.indices where workspace.steps[stepIndex].agentID == id { workspace.steps[stepIndex].agentID = fallback.id }
        selectedAgentID = fallback.id
    }

    func addStep(after stepID: UUID? = nil) {
        guard let agentID = selectedAgentID ?? workspace.agents.first?.id else { return }
        let role = workspace.agents.first(where: { $0.id == agentID })?.role
        let isCoder = role == .coder
        let isReviewer = role == .reviewer
        let step = WorkflowStep(
            title: isCoder ? "实现并验证代码" : "新步骤 \(workspace.steps.count + 1)",
            instruction: isCoder
                ? "检查当前项目并直接修改真实代码文件以完成目标；运行相关测试或构建，修复错误，并列出变更文件、验证结果和剩余风险。不得只返回伪代码。"
                : "描述输入、具体工作、真实交付物、完成判据和失败处理。",
            agentID: agentID,
            executionAccess: isReviewer ? .readOnly : .workspaceWrite
        )
        if let stepID, let index = workspace.steps.firstIndex(where: { $0.id == stepID }) { workspace.steps.insert(step, at: index + 1) }
        else { workspace.steps.append(step) }
        selectedStepID = step.id
        selectedAgentID = nil
    }

    func deleteStep(id: UUID) {
        guard let index = workspace.steps.firstIndex(where: { $0.id == id }) else { return }
        workspace.steps.remove(at: index)
        for other in workspace.steps.indices where workspace.steps[other].reviewReturnStepID == id { workspace.steps[other].reviewReturnStepID = nil }
        selectedStepID = workspace.steps.indices.contains(index) ? workspace.steps[index].id : workspace.steps.last?.id
    }

    func moveStep(id: UUID, offset: Int) {
        guard let source = workspace.steps.firstIndex(where: { $0.id == id }) else { return }
        let destination = source + offset
        guard workspace.steps.indices.contains(destination) else { return }
        workspace.steps.swapAt(source, destination)
        normalizeReviewLoops()
    }

    func replaceWorkflow(with steps: [WorkflowStep]) {
        guard !steps.isEmpty else { return }
        workspace.steps = steps
        normalizeReviewLoops()
        selectedStepID = workspace.steps.first?.id
        selectedAgentID = nil
    }

    func appendWorkflow(_ steps: [WorkflowStep]) {
        guard !steps.isEmpty else { return }
        workspace.steps.append(contentsOf: steps)
        normalizeReviewLoops()
        selectedStepID = steps.first?.id
        selectedAgentID = nil
    }

    func addProfile() {
        workspace.profiles.append(CodexProfile(name: "CLI 配置 \(workspace.profiles.count + 1)", reasoningEffort: .medium))
    }

    func setModel(_ modelID: String, forAgentID agentID: UUID) {
        guard let profileIndex = exclusiveProfileIndex(forAgentID: agentID) else { return }
        workspace.profiles[profileIndex].modelID = modelID
        let models = workspace.cliSettings.cachedModels
        let selected = modelID.isEmpty
            ? (models.first(where: \.isDefault) ?? models.first)
            : models.first(where: { $0.modelID == modelID })
        if let selected,
           !selected.supportedReasoningEfforts.contains(workspace.profiles[profileIndex].reasoningEffort) {
            workspace.profiles[profileIndex].reasoningEffort = selected.defaultReasoningEffort
        }
    }

    func setReasoningEffort(_ effort: ReasoningEffort, forAgentID agentID: UUID) {
        guard let profileIndex = exclusiveProfileIndex(forAgentID: agentID) else { return }
        workspace.profiles[profileIndex].reasoningEffort = effort
    }

    private func exclusiveProfileIndex(forAgentID agentID: UUID) -> Int? {
        guard let agentIndex = workspace.agents.firstIndex(where: { $0.id == agentID }) else { return nil }
        let profileID = workspace.agents[agentIndex].profileID
        let usageCount = workspace.agents.filter { $0.profileID == profileID }.count
        if usageCount > 1, let source = workspace.profiles.first(where: { $0.id == profileID }) {
            let copy = CodexProfile(
                name: "\(workspace.agents[agentIndex].name) 配置",
                modelID: source.modelID,
                reasoningEffort: source.reasoningEffort
            )
            workspace.profiles.append(copy)
            workspace.agents[agentIndex].profileID = copy.id
            return workspace.profiles.indices.last
        }
        return workspace.profiles.firstIndex(where: { $0.id == profileID })
    }

    func deleteProfile(id: UUID) {
        guard workspace.profiles.count > 1 else { return }
        workspace.profiles.removeAll { $0.id == id }
        guard let fallback = workspace.profiles.first?.id else { return }
        for index in workspace.agents.indices where workspace.agents[index].profileID == id { workspace.agents[index].profileID = fallback }
    }

    func archive(_ session: RunSession) {
        guard session.phase != .idle,
              let projectID = session.projectID,
              var project = projectSnapshot(projectID) else { return }
        archive(session, in: &project)
        applyProjectSnapshot(project)
    }

    func integrateAutomaticMemory(_ memory: MemoryRecord, projectID: UUID) {
        integrateAutomaticMemories([memory], projectID: projectID)
    }

    func integrateAutomaticMemories(_ memories: [MemoryRecord], projectID: UUID) {
        guard !memories.isEmpty, let project = projectSnapshot(projectID) else { return }
        let result = AutomaticMemoryService.upserting(memories, into: project)
        applyProjectSnapshot(result.project)
        if workspace.id == projectID {
            selectedMemoryID = result.records.last?.id
        }
    }

    func saveRunCheckpoint(_ checkpoint: RunCheckpoint, immediate: Bool) {
        guard projectSnapshot(checkpoint.projectID) != nil else { return }
        var snapshot = checkpoint
        snapshot.savedAt = Date()
        pendingRunCheckpoints[snapshot.projectID] = snapshot
        if workspace.id == snapshot.projectID {
            recoverableRunCheckpoint = snapshot
        }

        if immediate {
            checkpointWriteTasks[snapshot.projectID]?.cancel()
            checkpointWriteTasks[snapshot.projectID] = nil
            persistRunCheckpoint(snapshot)
            return
        }

        // Throttle streamed updates: persist the newest snapshot at most once per interval.
        // Boundary transitions use the immediate path above and are never delayed.
        let projectID = snapshot.projectID
        guard checkpointWriteTasks[projectID] == nil else { return }
        checkpointWriteTasks[projectID] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled, let self else { return }
            self.checkpointWriteTasks[projectID] = nil
            guard let latest = self.pendingRunCheckpoints[projectID] else { return }
            self.persistRunCheckpoint(latest)
        }
    }

    func clearRunCheckpoint(projectID: UUID) {
        checkpointWriteTasks[projectID]?.cancel()
        checkpointWriteTasks[projectID] = nil
        pendingRunCheckpoints[projectID] = nil
        if recoverableRunCheckpoint?.projectID == projectID {
            recoverableRunCheckpoint = nil
        }
        enqueueRemoval(
            at: runCheckpointURL(projectID: projectID),
            failurePrefix: "无法清理运行检查点"
        )
    }

    /// Starts a run-scoped memory transaction. Its baseline is written once,
    /// separately from the high-frequency checkpoint, so “restart” can restore
    /// records that were updated in place by a stable-key upsert.
    @discardableResult
    func beginRunMemoryTransaction(projectID: UUID, runID: UUID) -> Bool {
        guard let project = projectSnapshot(projectID) else { return false }
        let baseline = RunMemoryBaseline(
            projectID: projectID,
            runID: runID,
            memories: project.memories
        )
        runMemoryBaselines[projectID] = baseline
        enqueueMemoryBaselinePersistence(baseline)
        return true
    }

    func ensureRunMemoryTransaction(for checkpoint: RunCheckpoint) {
        if let existing = loadRunMemoryBaseline(projectID: checkpoint.projectID),
           existing.runID == checkpoint.session.id {
            runMemoryBaselines[checkpoint.projectID] = existing
            return
        }
        guard let project = projectSnapshot(checkpoint.projectID) else { return }
        // Legacy checkpoints predate transaction baselines. We cannot recover a
        // stable-key value that an old build already replaced, but we can still
        // prevent resumed-run records from leaking into a later restart.
        let baseline = RunMemoryBaseline(
            projectID: checkpoint.projectID,
            runID: checkpoint.session.id,
            memories: project.memories.filter { $0.relatedRunID != checkpoint.session.id }
        )
        runMemoryBaselines[checkpoint.projectID] = baseline
        enqueueMemoryBaselinePersistence(baseline)
    }

    /// Rolls back only the interrupted run's memory transaction, preserves the
    /// knowledge that existed before it, archives the interruption, and commits
    /// the whole reset as one background persistence operation.
    @discardableResult
    func restartFromCheckpoint(_ checkpoint: RunCheckpoint) -> Bool {
        guard var project = projectSnapshot(checkpoint.projectID) else { return false }
        var interrupted = checkpoint.session
        let now = Date()
        for index in interrupted.executions.indices where interrupted.executions[index].status == .running {
            interrupted.executions[index].status = .interrupted
            interrupted.executions[index].completedAt = now
            interrupted.executions[index].errorMessage = "应用异常退出，用户选择回滚本次并重新运行。"
        }
        interrupted.phase = .cancelled
        interrupted.completedAt = now
        interrupted.events.append(
            RunEvent(message: "用户选择回滚本次并重新运行；本次运行记忆已回滚，异常运行已保留为中断归档。", kind: "warning")
        )
        archive(interrupted, in: &project)

        if let baseline = loadRunMemoryBaseline(projectID: checkpoint.projectID),
           baseline.runID == checkpoint.session.id {
            project.memories = baseline.memories
        } else {
            project.memories.removeAll { $0.relatedRunID == checkpoint.session.id }
        }
        project = AutomaticMemoryService.synchronizeMainline(in: project)
        applyProjectSnapshot(project, shouldPersist: false)
        clearRunTransactionState(projectID: checkpoint.projectID)
        enqueueTerminalPersistence(library, projectID: checkpoint.projectID)
        return true
    }

    /// Adds the run summary and archive in one in-memory mutation, then writes
    /// the project library and removes recovery files on the background lane.
    func finalizeRun(_ session: RunSession) {
        guard session.phase != .idle,
              let projectID = session.projectID,
              var project = projectSnapshot(projectID) else { return }
        let summary = AutomaticMemoryService.runSummary(from: session)
        project = AutomaticMemoryService.upserting(summary, into: project).project
        archive(session, in: &project)
        applyProjectSnapshot(project, shouldPersist: false)
        clearRunTransactionState(projectID: projectID)
        enqueueTerminalPersistence(library, projectID: projectID)
    }

    func refreshCodexCLI() async {
        guard !isRefreshingCLI else { return }
        isRefreshingCLI = true
        defer { isRefreshingCLI = false }
        cliMessage = "正在读取本机 Codex CLI…"
        let projectID = workspace.id
        let path = workspace.cliSettings.executablePath
        do {
            let inspection = try await CodexCLIService.inspect(executablePath: path)
            guard workspace.id == projectID else {
                cliMessage = "项目已切换，本次 CLI 检测结果未写入。"
                return
            }
            var updated = workspace
            updated.cliSettings.cachedModels = inspection.models
            updated.cliSettings.cliVersion = inspection.version
            updated.cliSettings.loginSummary = inspection.loginSummary
            updated.cliSettings.lastRefreshedAt = Date()
            normalizeProfiles(in: &updated)
            setWorkspaceInternally(updated)
            cliMessage = "已连接：\(inspection.version)，发现 \(inspection.models.count) 个可选模型。"
        } catch {
            cliMessage = error.localizedDescription
        }
    }

    func projectDirectory(for projectID: UUID) throws -> URL {
        let selectedProject: ProjectWorkspace?
        if workspace.id == projectID {
            selectedProject = workspace
        } else {
            selectedProject = library.projects.first(where: { $0.id == projectID })
        }
        guard let project = selectedProject else {
            throw ProjectDirectoryError.projectNotFound
        }
        let configured = project.projectDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if configured.isEmpty {
            let directory = managedProjectDirectory(for: projectID)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        }

        let expanded = (configured as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { throw ProjectDirectoryError.notAbsolute(configured) }
        let directory = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ProjectDirectoryError.notDirectory(directory.path)
        }
        guard FileManager.default.isReadableFile(atPath: directory.path) else {
            throw ProjectDirectoryError.notReadable(directory.path)
        }
        return directory
    }

    func managedProjectDirectory(for projectID: UUID) -> URL {
        storageURL.deletingLastPathComponent()
            .appendingPathComponent("Projects", isDirectory: true)
            .appendingPathComponent(projectID.uuidString, isDirectory: true)
    }

    func projectDirectoryDisplayPath(for projectID: UUID) -> String {
        let configured = workspace.id == projectID ? workspace.projectDirectoryPath : library.projects.first(where: { $0.id == projectID })?.projectDirectoryPath ?? ""
        return configured.isEmpty ? managedProjectDirectory(for: projectID).path : configured
    }

    private func normalizeProfiles(in project: inout ProjectWorkspace) {
        let models = project.cliSettings.cachedModels
        for index in project.profiles.indices {
            let selected: CLIModelDescriptor?
            if project.profiles[index].modelID.isEmpty { selected = models.first(where: \.isDefault) ?? models.first }
            else { selected = models.first(where: { $0.modelID == project.profiles[index].modelID }) }
            if let selected, !selected.supportedReasoningEfforts.contains(project.profiles[index].reasoningEffort) {
                project.profiles[index].reasoningEffort = selected.defaultReasoningEffort
            }
        }
    }

    private func loadRunCheckpointForSelectedProject() {
        recoverableRunCheckpoint = pendingRunCheckpoints[workspace.id]
            ?? Self.loadRunCheckpoint(projectID: workspace.id, storageURL: storageURL)
        if let checkpoint = recoverableRunCheckpoint {
            pendingRunCheckpoints[workspace.id] = checkpoint
        }
    }

    private static func loadRunCheckpoint(projectID: UUID, storageURL: URL) -> RunCheckpoint? {
        let url = checkpointURL(projectID: projectID, storageURL: storageURL)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let checkpoint = try? decoder.decode(RunCheckpoint.self, from: data),
              checkpoint.schemaVersion == 1,
              checkpoint.projectID == projectID,
              checkpoint.session.projectID == projectID,
              checkpoint.session.phase == .running || checkpoint.session.phase == .awaitingApproval else {
            return nil
        }
        return checkpoint
    }

    /// 0.1.2 archived cancellation before its active execution was changed from `.running`.
    /// That inconsistent terminal session is a reliable one-time signal that useful partial state
    /// remains even though the old release had no standalone checkpoint file.
    private static func legacyInterruptedCheckpoint(
        in project: ProjectWorkspace,
        sourceSchemaVersion: Int
    ) -> RunCheckpoint? {
        guard sourceSchemaVersion < 5,
              var session = project.runHistory.first(where: {
                  $0.phase == .cancelled && $0.executions.contains(where: { $0.status == .running })
              }),
              session.projectID == nil || session.projectID == project.id,
              let runningExecution = session.executions.last(where: { $0.status == .running }) else {
            return nil
        }

        let nextStepIndex: Int
        if let savedIndex = session.currentStepIndex, project.steps.indices.contains(savedIndex) {
            nextStepIndex = savedIndex
        } else if let resolvedIndex = project.steps.firstIndex(where: { $0.id == runningExecution.stepID }) {
            nextStepIndex = resolvedIndex
        } else {
            return nil
        }

        let checkpointDate = session.completedAt ?? runningExecution.completedAt ?? runningExecution.startedAt
        session.phase = .running
        session.completedAt = nil
        session.errorMessage = nil
        session.currentStepIndex = nextStepIndex
        session.projectID = project.id
        session.events.append(
            RunEvent(
                message: "已从 0.1.2 的不完整取消记录重建异常恢复检查点。",
                kind: "recovery"
            )
        )

        let executedStepIDs = Set(session.executions.map(\.stepID))
        let approvedGateIDs = project.steps
            .filter { $0.requiresApproval && executedStepIDs.contains($0.id) }
            .map(\.id)

        var retries: [ReviewRetryCheckpoint] = []
        for step in project.steps {
            let role = project.agents.first(where: { $0.id == step.agentID })?.role
            guard role == .reviewer || step.reviewReturnStepID != nil else { continue }
            let failureCount = session.executions.filter {
                $0.stepID == step.id && $0.status == .completed && ReviewVerdictParser.parse($0.output) == .fail
            }.count
            if failureCount > 0 {
                retries.append(
                    ReviewRetryCheckpoint(
                        reviewerStepID: step.id,
                        retryCount: min(failureCount, step.maxReviewRetries)
                    )
                )
            }
        }

        return RunCheckpoint(
            projectID: project.id,
            session: session,
            nextStepIndex: nextStepIndex,
            approvedGateIDs: approvedGateIDs,
            reviewRetryCounts: retries,
            savedAt: checkpointDate
        )
    }

    private func persistRunCheckpoint(_ checkpoint: RunCheckpoint) {
        let url = runCheckpointURL(projectID: checkpoint.projectID)
        enqueueJSONWrite(
            checkpoint,
            to: url,
            prettyPrinted: false,
            failurePrefix: "运行检查点保存失败"
        )
    }

    private func runCheckpointURL(projectID: UUID) -> URL {
        Self.checkpointURL(projectID: projectID, storageURL: storageURL)
    }

    private static func checkpointURL(projectID: UUID, storageURL: URL) -> URL {
        storageURL.deletingLastPathComponent()
            .appendingPathComponent("RunCheckpoints", isDirectory: true)
            .appendingPathComponent("\(projectID.uuidString).json")
    }

    private func runMemoryBaselineURL(projectID: UUID) -> URL {
        storageURL.deletingLastPathComponent()
            .appendingPathComponent("RunMemoryBaselines", isDirectory: true)
            .appendingPathComponent("\(projectID.uuidString).json")
    }

    private func enqueueMemoryBaselinePersistence(_ baseline: RunMemoryBaseline) {
        enqueueJSONWrite(
            baseline,
            to: runMemoryBaselineURL(projectID: baseline.projectID),
            prettyPrinted: false,
            failurePrefix: "运行记忆基线保存失败"
        )
    }

    private func loadRunMemoryBaseline(projectID: UUID) -> RunMemoryBaseline? {
        if let inMemory = runMemoryBaselines[projectID] { return inMemory }
        let url = runMemoryBaselineURL(projectID: projectID)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let baseline = try? decoder.decode(RunMemoryBaseline.self, from: data),
              baseline.schemaVersion == 1,
              baseline.projectID == projectID else { return nil }
        return baseline
    }

    private func clearRunMemoryBaseline(projectID: UUID) {
        runMemoryBaselines[projectID] = nil
        enqueueRemoval(
            at: runMemoryBaselineURL(projectID: projectID),
            failurePrefix: "无法清理运行记忆基线"
        )
    }

    private func clearRunTransactionState(projectID: UUID) {
        checkpointWriteTasks[projectID]?.cancel()
        checkpointWriteTasks[projectID] = nil
        pendingRunCheckpoints[projectID] = nil
        runMemoryBaselines[projectID] = nil
        if recoverableRunCheckpoint?.projectID == projectID {
            recoverableRunCheckpoint = nil
        }
    }

    private func normalizeReviewLoops() {
        for index in workspace.steps.indices {
            workspace.steps[index].maxReviewRetries = min(max(workspace.steps[index].maxReviewRetries, 1), 5)
            guard let target = workspace.steps[index].reviewReturnStepID,
                  let targetIndex = workspace.steps.firstIndex(where: { $0.id == target }),
                  targetIndex < index else {
                workspace.steps[index].reviewReturnStepID = nil
                continue
            }
        }
    }

    private func scheduleAutomaticMemory(from baseline: ProjectWorkspace) {
        if automaticMemoryBaseline == nil { automaticMemoryBaseline = baseline }
        automaticMemoryTask?.cancel()
        automaticMemoryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 850_000_000)
            guard !Task.isCancelled else { return }
            self?.commitAutomaticMemoryNow()
        }
    }

    private func commitAutomaticMemoryNow() {
        automaticMemoryTask?.cancel()
        automaticMemoryTask = nil
        let baseline = automaticMemoryBaseline
        automaticMemoryBaseline = nil
        var updated = AutomaticMemoryService.synchronizeMainline(in: workspace)
        if let baseline, let log = AutomaticMemoryService.changeLog(from: baseline, to: workspace) {
            updated = AutomaticMemoryService.appending(log, to: updated)
        }
        setWorkspaceInternally(updated)
    }

    private func projectSnapshot(_ projectID: UUID) -> ProjectWorkspace? {
        if workspace.id == projectID { return workspace }
        return library.projects.first(where: { $0.id == projectID })
    }

    private func applyProjectSnapshot(_ newValue: ProjectWorkspace, shouldPersist: Bool = true) {
        if workspace.id == newValue.id {
            setWorkspaceInternally(newValue, shouldPersist: shouldPersist)
            return
        }
        guard let index = library.projects.firstIndex(where: { $0.id == newValue.id }) else { return }
        library.projects[index] = newValue
        library.updatedAt = Date()
        if shouldPersist { persistWithoutSync() }
    }

    private func archive(_ session: RunSession, in project: inout ProjectWorkspace) {
        project.runHistory.removeAll { $0.id == session.id }
        project.runHistory.insert(session, at: 0)
        project.runHistory = Array(project.runHistory.prefix(20))
    }

    private func setWorkspaceInternally(_ newValue: ProjectWorkspace, shouldPersist: Bool = true) {
        isInternalMutation = true
        workspace = newValue
        syncWorkspaceIntoLibrary()
        if shouldPersist { persistWithoutSync() }
        isInternalMutation = false
    }

    private func syncWorkspaceIntoLibrary() {
        guard isReady || !library.projects.isEmpty else { return }
        if let index = library.projects.firstIndex(where: { $0.id == workspace.id }) { library.projects[index] = workspace }
        else { library.projects.append(workspace) }
        library.selectedProjectID = workspace.id
        library.updatedAt = Date()
    }

    private func persistWithoutSync() {
        library.updatedAt = Date()
        enqueueLibraryPersistence(library)
    }

    private func enqueueLibraryPersistence(_ snapshot: WorkspaceLibrary) {
        enqueueJSONWrite(
            snapshot,
            to: storageURL,
            prettyPrinted: true,
            failurePrefix: "本地保存失败"
        )
    }

    private func enqueueTerminalPersistence(_ snapshot: WorkspaceLibrary, projectID: UUID) {
        persistenceRevision += 1
        let revision = persistenceRevision
        let workspaceURL = storageURL
        let checkpointURL = runCheckpointURL(projectID: projectID)
        let baselineURL = runMemoryBaselineURL(projectID: projectID)
        persistenceQueue.async { [weak self] in
            do {
                try Self.writeJSON(snapshot, to: workspaceURL, prettyPrinted: true)
                for url in [checkpointURL, baselineURL] where FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
                Task { @MainActor [weak self] in
                    self?.reportPersistenceResult(nil, revision: revision)
                }
            } catch {
                let message = "运行收尾保存失败：\(error.localizedDescription)"
                Task { @MainActor [weak self] in
                    self?.reportPersistenceResult(message, revision: revision)
                }
            }
        }
    }

    private func enqueueJSONWrite<Value: Encodable>(
        _ value: Value,
        to url: URL,
        prettyPrinted: Bool,
        failurePrefix: String
    ) {
        persistenceRevision += 1
        let revision = persistenceRevision
        persistenceQueue.async { [weak self] in
            do {
                try Self.writeJSON(value, to: url, prettyPrinted: prettyPrinted)
                Task { @MainActor [weak self] in
                    self?.reportPersistenceResult(nil, revision: revision)
                }
            } catch {
                let message = "\(failurePrefix)：\(error.localizedDescription)"
                Task { @MainActor [weak self] in
                    self?.reportPersistenceResult(message, revision: revision)
                }
            }
        }
    }

    private func enqueueRemoval(at url: URL, failurePrefix: String) {
        persistenceRevision += 1
        let revision = persistenceRevision
        persistenceQueue.async { [weak self] in
            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
                Task { @MainActor [weak self] in
                    self?.reportPersistenceResult(nil, revision: revision)
                }
            } catch {
                let message = "\(failurePrefix)：\(error.localizedDescription)"
                Task { @MainActor [weak self] in
                    self?.reportPersistenceResult(message, revision: revision)
                }
            }
        }
    }

    private func reportPersistenceResult(_ message: String?, revision: Int) {
        if let message {
            persistenceMessage = message
        } else if revision == persistenceRevision {
            persistenceMessage = nil
        }
    }

    nonisolated private static func writeJSON<Value: Encodable>(
        _ value: Value,
        to url: URL,
        prettyPrinted: Bool
    ) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = prettyPrinted
            ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}

private struct RunMemoryBaseline: Codable, Hashable {
    var schemaVersion: Int = 1
    var projectID: UUID
    var runID: UUID
    var memories: [MemoryRecord]
    var savedAt: Date = Date()
}

private enum ProjectDirectoryError: LocalizedError {
    case projectNotFound
    case notAbsolute(String)
    case notDirectory(String)
    case notReadable(String)

    var errorDescription: String? {
        switch self {
        case .projectNotFound:
            return "找不到当前项目。"
        case .notAbsolute(let path):
            return "项目路径必须是绝对路径：\(path)"
        case .notDirectory(let path):
            return "项目路径不存在或不是文件夹：\(path)"
        case .notReadable(let path):
            return "当前用户无法读取项目文件夹：\(path)"
        }
    }
}
