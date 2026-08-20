import Combine
import Foundation

/// Owns one orchestration engine per project so switching projects never moves,
/// resets, or serializes another project's active Codex CLI run.
@MainActor
final class ProjectRunRegistry: ObservableObject {
    private var engines: [UUID: OrchestrationEngine] = [:]
    private var subscriptions: [UUID: AnyCancellable] = [:]

    var activeProjectIDs: Set<UUID> {
        Set(engines.compactMap { projectID, engine in
            engine.isActive ? projectID : nil
        })
    }

    var activeCount: Int { activeProjectIDs.count }

    func engine(for projectID: UUID) -> OrchestrationEngine {
        if let existing = engines[projectID] { return existing }

        let engine = OrchestrationEngine()
        engines[projectID] = engine
        subscriptions[projectID] = engine.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        return engine
    }

    func phase(for projectID: UUID) -> RunPhase {
        engines[projectID]?.session.phase ?? .idle
    }

    func isActive(_ projectID: UUID) -> Bool {
        engines[projectID]?.isActive == true
    }

    func discard(projectID: UUID) {
        guard engines[projectID]?.isActive != true else { return }
        subscriptions[projectID] = nil
        engines[projectID] = nil
        objectWillChange.send()
    }
}
