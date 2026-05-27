//
//  BackgroundScanScheduler.swift
//  MacSentinel
//
//  Weekly opportunistic scan via NSBackgroundActivityScheduler. When the
//  scan finds something noteworthy (e.g. > 500 MB reclaimable cache or
//  > 1 GB duplicate groups), posts a UNUserNotification to alert the user.
//
//  Lifecycle:
//   • register() at app launch (idempotent — called from AppDelegate)
//   • the scheduler waits for an opportunistic moment (low CPU + on AC)
//     within the user-configured interval to run quickScan()
//   • toggleable from Settings via UserDefaults key `backgroundScanEnabled`
//

import Foundation
import UserNotifications
import AppKit

@MainActor
final class BackgroundScanScheduler {

    static let shared = BackgroundScanScheduler()

    static let enabledKey  = "backgroundScanEnabled"
    static let intervalKey = "backgroundScanIntervalDays"     // default 7
    private let activityID = "com.macsentinel.app.weeklyScan"

    private var activity: NSBackgroundActivityScheduler?

    /// First-run default = true. User can opt out in Settings.
    var isEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: Self.enabledKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: Self.enabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            if newValue { register() } else { unregister() }
        }
    }

    var intervalDays: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: Self.intervalKey)
            return v > 0 ? v : 7
        }
        set { UserDefaults.standard.set(max(1, newValue), forKey: Self.intervalKey) }
    }

    private init() {}

    // MARK: - Registration

    func register() {
        guard isEnabled else { return }
        unregister()
        let activity = NSBackgroundActivityScheduler(identifier: activityID)
        activity.repeats  = true
        activity.interval = TimeInterval(intervalDays) * 86400      // seconds between runs
        activity.tolerance = activity.interval / 4                  // allow ±25% slack
        activity.qualityOfService = .utility
        activity.schedule { [weak self] completion in
            Task { @MainActor in
                await self?.quickScan()
                completion(.finished)
            }
        }
        self.activity = activity
    }

    func unregister() {
        activity?.invalidate()
        activity = nil
    }

    // MARK: - Quick scan (≤ ~30s)

    func quickScan() async {
        // 1. Permission for notifications (no-op if already granted)
        await requestNotificationPermissionIfNeeded()

        // 2. Cheap cache scan (already optimised, ~5-15s)
        let cacheResult = await CacheScanner.shared.scan()
        let reclaimable = cacheResult.totalReclaimableBytes

        var lines: [String] = []
        if reclaimable >= 100 * 1024 * 1024 {
            lines.append("可清快取 \(ByteFormatter.format(reclaimable))")
        }

        // 3. Quick large-file probe (only Downloads + Desktop to stay fast)
        let largeOpts = LargeFileScanOptions(
            minSizeBytes: 500 * 1024 * 1024,
            minDays: 90,
            roots: [
                FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads"),
                FileManager.default.homeDirectoryForCurrentUser.appending(path: "Desktop")
            ]
        )
        let largeFiles = await LargeFileScanner.shared.scan(options: largeOpts)
        let largeTotal = largeFiles.reduce(UInt64(0)) { $0 + $1.sizeBytes }
        if largeTotal >= 500 * 1024 * 1024 {
            lines.append("大檔（>500 MB 且 >90 天）\(largeFiles.count) 個共 \(ByteFormatter.format(largeTotal))")
        }

        // 4. Audit
        await AuditLog.shared.record(.scanCompleted(
            type: "weekly_quick",
            itemsFound: cacheResult.categories.reduce(0) { $0 + $1.items.count } + largeFiles.count,
            totalBytes: reclaimable + largeTotal
        ))

        // 5. Notify if there's actually something for the user
        guard !lines.isEmpty else { return }
        await postNotification(lines: lines)
    }

    // MARK: - Notifications

    private func requestNotificationPermissionIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        default:
            break
        }
    }

    private func postNotification(lines: [String]) async {
        let content = UNMutableNotificationContent()
        content.title = "MacSentinel 每週掃描"
        content.subtitle = "發現可清的項目"
        content.body = lines.joined(separator: "\n")
        content.sound = .default
        content.categoryIdentifier = "weekly_scan"

        let req = UNNotificationRequest(
            identifier: "macsentinel.weekly.\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil      // deliver immediately
        )
        try? await UNUserNotificationCenter.current().add(req)
    }

    /// Manual trigger from Settings — also useful as a "run now" button.
    func runManually() async {
        await quickScan()
    }
}
