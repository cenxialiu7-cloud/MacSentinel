import SwiftUI
import AppKit

@main
struct MacSentinelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    private let collector = SystemDataCollector.shared
    private let processService = ProcessSnapshotService.shared

    init() {
        // Pre-warm signature trust cache so the first user-visible scan is fast.
        ProcessTrustService.shared.warmCache()
    }

    var body: some Scene {
        WindowGroup("MacSentinel") {
            ContentView()
                .frame(minWidth: 900, minHeight: 600)
                .environment(collector)
                .environment(processService)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView()
        }
    }
}
