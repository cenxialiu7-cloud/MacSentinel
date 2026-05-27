import AppKit
import SwiftUI
import Sparkle

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?

    /// Sparkle in-app auto-update controller.
    /// `startingUpdater: true` → 啟動時依 Info.plist 的 SUScheduledCheckInterval 排程檢查
    /// 公鑰寫在 Info.plist (SUPublicEDKey)，appcast URL 在 SUFeedURL
    let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        SystemDataCollector.shared.start()
        ProcessSnapshotService.shared.start()
        // Opportunistic weekly background scan (NSBackgroundActivityScheduler).
        BackgroundScanScheduler.shared.register()
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
            // 攔截左鍵 + 右鍵，左鍵照舊 toggle popover，右鍵彈出選單（含「檢查更新…」）
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.action = #selector(handleStatusItemClick(_:))
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

    @objc private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || (event?.modifierFlags.contains(.control) ?? false) {
            showStatusItemMenu(from: sender)
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = statusItem?.button, let popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func showStatusItemMenu(from button: NSStatusBarButton) {
        let menu = NSMenu()
        menu.addItem(withTitle: "開啟 MacSentinel",
                     action: #selector(openMainWindow),
                     keyEquivalent: "")
        menu.addItem(.separator())

        // Sparkle 標準的 "Check for Updates…" 選單項目。
        // updaterController 內含可重用的 target/action，會自動 enable/disable。
        let updateItem = NSMenuItem(title: "檢查更新…",
                                    action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
                                    keyEquivalent: "")
        updateItem.target = updaterController
        menu.addItem(updateItem)

        menu.addItem(.separator())
        menu.addItem(withTitle: "結束 MacSentinel",
                     action: #selector(NSApplication.terminate(_:)),
                     keyEquivalent: "q")

        // 暫時 attach 到 statusItem 才能 popUp，顯示後立刻清掉避免左鍵也彈選單。
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
            return
        }
    }
}
