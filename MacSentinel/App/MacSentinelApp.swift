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
        // id="main" is required so that other parts of the app (e.g. the
        // status-bar popover's "開啟主介面" button) can call openWindow(id:"main")
        // to bring the main window forward. Without an explicit id, openWindow
        // silently fails on LSUIElement apps that have no Dock icon.
        WindowGroup("MacSentinel", id: "main") {
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
