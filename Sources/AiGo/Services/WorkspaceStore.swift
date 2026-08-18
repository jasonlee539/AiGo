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

    let storageURL: URL
    private var isReady = false
    private var isInternalMutation = false
    private var automaticMemoryBaseline: ProjectWorkspace?
    private var automaticMemoryTask: Task<Void, Never>?

    var projects: [ProjectWorkspace] { library.projects }

    init(storageURL: URL? = nil) {
        self.storageURL = storageURL ?? Self.defaultStorageURL()
        let legacyBackupMessage = Self.backUpLegacyWorkspaceIfNeeded(at: self.storageURL)
        var loaded = Self.loadLibrary(from: self.storageURL) ?? .starter()
        loaded.sanitize()
        let selected = loaded.projects.first(where: { $0.id == loaded.selectedProjectID }) ?? loaded.projects[0]
        let synchronized = AutomaticMemoryService.synchronizeMainline(in: selected)
        if let index = loaded.projects.firstIndex(where: { $0.id == selected.id }) { loaded.projects[index] = synchronized }
        self.library = loaded
        self.workspace = synchronized
        self.selectedAgentID = synchronized.agents.first?.id
        self.selectedStepID = synchronized.steps.first?.id
        self.selectedMemoryID = synchronized.memories.first?.id
        self.migrationMessage = legacyBackupMessage
        self.isReady = true
        persist()
    }

    deinit { automaticMemoryTask?.cancel() }

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
            return WorkspaceLibrary(schemaVersion: 3, selectedProjectID: legacyProject.id, projects: [legacyProject], updatedAt: Date())
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

    func persist() {
        syncWorkspaceIntoLibrary()
        do {
            let directory = storageURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var snapshot = library
            snapshot.updatedAt = Date()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(snapshot).write(to: storageURL, options: .atomic)
            persistenceMessage = nil
        } catch {
            persistenceMessage = "本地保存失败：\(error.localizedDescription)"
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
    }

    func deleteCurrentProject() {
        guard library.projects.count > 1,
              let index = library.projects.firstIndex(where: { $0.id == workspace.id }) else { return }
        automaticMemoryTask?.cancel()
        automaticMemoryBaseline = nil
        library.projects.remove(at: index)
        let next = library.projects[min(index, library.projects.count - 1)]
        library.selectedProjectID = next.id
        setWorkspaceInternally(next)
        selectedAgentID = next.agents.first?.id
        selectedStepID = next.steps.first?.id
        selectedMemoryID = next.memories.first?.id
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
        let step = WorkflowStep(title: "新步骤 \(workspace.steps.count + 1)", instruction: "描述输入、工作要求、输出格式和完成判据。", agentID: agentID)
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
    }

    func addProfile() {
        workspace.profiles.append(CodexProfile(name: "CLI 配置 \(workspace.profiles.count + 1)", reasoningEffort: .medium))
    }

    func deleteProfile(id: UUID) {
        guard workspace.profiles.count > 1 else { return }
        workspace.profiles.removeAll { $0.id == id }
        guard let fallback = workspace.profiles.first?.id else { return }
        for index in workspace.agents.indices where workspace.agents[index].profileID == id { workspace.agents[index].profileID = fallback }
    }

    func archive(_ session: RunSession) {
        guard session.phase != .idle, session.projectID == workspace.id else { return }
        workspace.runHistory.removeAll { $0.id == session.id }
        workspace.runHistory.insert(session, at: 0)
        workspace.runHistory = Array(workspace.runHistory.prefix(20))
    }

    func integrateAutomaticMemory(_ memory: MemoryRecord, projectID: UUID) {
        guard workspace.id == projectID else { return }
        let result = AutomaticMemoryService.upserting(memory, into: workspace)
        setWorkspaceInternally(result.project)
        selectedMemoryID = result.record.id
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

    private func setWorkspaceInternally(_ newValue: ProjectWorkspace) {
        isInternalMutation = true
        workspace = newValue
        syncWorkspaceIntoLibrary()
        persistWithoutSync()
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
        do {
            let directory = storageURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(library).write(to: storageURL, options: .atomic)
            persistenceMessage = nil
        } catch {
            persistenceMessage = "本地保存失败：\(error.localizedDescription)"
        }
    }
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
