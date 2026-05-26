import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        SystemDataCollector.shared.start()
        ProcessSnapshotService.shared.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false  // Keep running in menu bar even if window is closed
    }

    // MARK: - Menu Bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "shield.checkered",
                                    accessibilityDescription: "MacSentinel")
            button.action = #selector(togglePopover)
            button.target = self
        }

        let popoverView = MenuBarPopoverView()
            .environment(SystemDataCollector.shared)

        let popover = NSPopover()
        popover.contentViewController = NSHostingController(rootView: popoverView)
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 280, height: 340)
        self.popover = popover
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button, let popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}
