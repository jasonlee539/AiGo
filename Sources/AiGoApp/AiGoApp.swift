import AiGoKit
import SwiftUI

@main
struct AiGoApp: App {
    var body: some Scene {
        WindowGroup("AiGo", id: "main") {
            AiGoRootView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1_280, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
