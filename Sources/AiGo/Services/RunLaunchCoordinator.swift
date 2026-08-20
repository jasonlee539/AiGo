import Foundation

@MainActor
enum RunLaunchCoordinator {
    @discardableResult
    static func startNew(store: WorkspaceStore, engine: OrchestrationEngine) -> Bool {
        guard !engine.isActive else { return false }
        guard store.recoverableRunCheckpoint == nil else {
            store.persistenceMessage = "检测到上次异常运行，请先选择“从中断处继续”或“回滚本次并重新运行”。"
            return false
        }
        guard let directory = resolvedDirectory(store: store) else { return false }
        return launchNew(store: store, engine: engine, directory: directory)
    }

    @discardableResult
    static func restart(
        store: WorkspaceStore,
        engine: OrchestrationEngine,
        checkpoint: RunCheckpoint
    ) -> Bool {
        guard !engine.isActive, checkpoint.projectID == store.workspace.id else { return false }
        guard let directory = resolvedDirectory(store: store) else { return false }
        guard store.restartFromCheckpoint(checkpoint) else { return false }
        return launchNew(store: store, engine: engine, directory: directory)
    }

    @discardableResult
    static func resume(
        store: WorkspaceStore,
        engine: OrchestrationEngine,
        checkpoint: RunCheckpoint
    ) -> Bool {
        guard !engine.isActive, checkpoint.projectID == store.workspace.id else { return false }
        guard let directory = resolvedDirectory(store: store) else { return false }
        let projectID = store.workspace.id
        store.ensureRunMemoryTransaction(for: checkpoint)
        store.selectedSection = .run
        engine.resume(
            workspace: store.workspace,
            workingDirectory: directory,
            checkpoint: checkpoint,
            onMemory: { [weak store] memories in
                store?.integrateAutomaticMemories(memories, projectID: projectID)
            },
            onCheckpoint: checkpointHandler(store: store, projectID: projectID),
            onFinish: { [weak store] session in
                store?.finalizeRun(session)
            }
        )
        return true
    }

    private static func launchNew(
        store: WorkspaceStore,
        engine: OrchestrationEngine,
        directory: URL
    ) -> Bool {
        let projectID = store.workspace.id
        let runID = UUID()
        guard store.beginRunMemoryTransaction(projectID: projectID, runID: runID) else {
            store.persistenceMessage = "无法为当前项目建立运行记忆事务。"
            return false
        }
        store.selectedSection = .run
        engine.start(
            workspace: store.workspace,
            workingDirectory: directory,
            runID: runID,
            onMemory: { [weak store] memories in
                store?.integrateAutomaticMemories(memories, projectID: projectID)
            },
            onCheckpoint: checkpointHandler(store: store, projectID: projectID),
            onFinish: { [weak store] session in
                store?.finalizeRun(session)
            }
        )
        return true
    }

    private static func checkpointHandler(
        store: WorkspaceStore,
        projectID: UUID
    ) -> (RunCheckpoint?, Bool) -> Void {
        { [weak store] checkpoint, immediate in
            guard let store else { return }
            if let checkpoint {
                store.saveRunCheckpoint(checkpoint, immediate: immediate)
            } else {
                store.clearRunCheckpoint(projectID: projectID)
            }
        }
    }

    private static func resolvedDirectory(store: WorkspaceStore) -> URL? {
        do {
            return try store.projectDirectory(for: store.workspace.id)
        } catch {
            store.persistenceMessage = "无法建立项目工作目录：\(error.localizedDescription)"
            return nil
        }
    }
}
