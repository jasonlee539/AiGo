import SwiftUI

public struct AiGoRootView: View {
    @StateObject private var store = WorkspaceStore()
    @StateObject private var engine = OrchestrationEngine()

    public init() {}

    public var body: some View {
        MainView()
            .environmentObject(store)
            .environmentObject(engine)
            .frame(minWidth: 1_100, minHeight: 720)
    }
}
