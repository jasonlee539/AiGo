import SwiftUI

public struct AiGoRootView: View {
    @StateObject private var store = WorkspaceStore()
    @StateObject private var runRegistry = ProjectRunRegistry()

    public init() {}

    public var body: some View {
        MainView()
            .environmentObject(store)
            .environmentObject(runRegistry)
            .frame(minWidth: 1_100, minHeight: 720)
    }
}
