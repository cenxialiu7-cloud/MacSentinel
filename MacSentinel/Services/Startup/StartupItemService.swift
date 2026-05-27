//
//  StartupItemService.swift
//  MacSentinel
//
//  Scans LaunchAgents / LaunchDaemons across the three standard locations
//  and lets the user toggle each item's Disabled flag.
//
//  Toggle strategy:
//    • User-level (~/Library/LaunchAgents) → direct plist rewrite + launchctl
//    • System-level (/Library/Launch*)     → osascript with administrator
//      privileges (system prompt for password) + launchctl bootout/bootstrap
//

import Foundation

@MainActor
final class StartupItemService {

    static let shared = StartupItemService()
    private let fm = FileManager.default

    /// The three standard LaunchAgent/Daemon directories.
    static let agentDirs: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/Library/LaunchAgents",
            "/Library/LaunchAgents",
            "/Library/LaunchDaemons"
        ]
    }()

    private init() {}

    // MARK: - Scan

    func scan() async -> [StartupItem] {
        await Task.detached(priority: .utility) {
            self.collectItems()
        }.value
    }

    nonisolated private func collectItems() -> [StartupItem] {
        var items: [StartupItem] = []
        let fm = FileManager.default
        for dir in Self.agentDirs {
            guard fm.fileExists(atPath: dir) else { continue }
            let isSystem = dir.hasPrefix("/Library")
            let contents = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
            for plistName in contents where plistName.hasSuffix(".plist") {
                let plistPath = (dir as NSString).appendingPathComponent(plistName)
                guard let data = fm.contents(atPath: plistPath),
                      let plist = try? PropertyListSerialization
                        .propertyList(from: data, options: [], format: nil)
                        as? [String: Any] else { continue }

                let label = plist["Label"] as? String ?? plistName
                let program: String = {
                    if let p = plist["Program"] as? String { return p }
                    if let pa = plist["ProgramArguments"] as? [String], let first = pa.first {
                        return first
                    }
                    return "未知"
                }()
                let isDisabled = (plist["Disabled"] as? Bool) ?? false

                var item = StartupItem(
                    label: label,
                    name: (plistName as NSString).deletingPathExtension,
                    path: plistPath,
                    program: program,
                    isEnabled: !isDisabled,
                    isSystemLevel: isSystem
                )
                StartupKnowledgeBase.evaluate(&item)
                items.append(item)
            }
        }
        return items.sorted { $0.label.lowercased() < $1.label.lowercased() }
    }

    // MARK: - Toggle

    /// Result describing what happened (success / cancelled / error).
    struct ToggleResult {
        let success: Bool
        let message: String
    }

    /// Enable or disable a startup item by rewriting its plist's Disabled key
    /// and re-loading it via launchctl. For system-level items, runs through
    /// `osascript ... administrator privileges` so macOS prompts for password.
    func toggle(_ item: StartupItem, enable: Bool) async -> ToggleResult {
        await Task.detached(priority: .userInitiated) {
            self.performToggle(item, enable: enable)
        }.value
    }

    nonisolated private func performToggle(_ item: StartupItem, enable: Bool) -> ToggleResult {
        let fm = FileManager.default
        guard let data = fm.contents(atPath: item.path),
              var plist = try? PropertyListSerialization
                .propertyList(from: data, options: .mutableContainersAndLeaves, format: nil)
                as? [String: Any] else {
            return .init(success: false, message: "無法讀取 plist 檔案。")
        }
        plist["Disabled"] = !enable

        guard let newData = try? PropertyListSerialization
            .data(fromPropertyList: plist, format: .xml, options: 0) else {
            return .init(success: false, message: "無法序列化 plist。")
        }

        if item.isSystemLevel {
            // Stage into temp, then cp + launchctl via osascript admin
            let tmp = NSTemporaryDirectory() + UUID().uuidString + ".plist"
            do {
                try newData.write(to: URL(fileURLWithPath: tmp))
            } catch {
                return .init(success: false, message: "無法寫入暫存檔：\(error.localizedDescription)")
            }
            defer { try? fm.removeItem(atPath: tmp) }

            let launchctlVerb = enable ? "load" : "unload"
            let escapedSrc = tmp.replacingOccurrences(of: "'", with: "'\\''")
            let escapedDst = item.path.replacingOccurrences(of: "'", with: "'\\''")
            let escapedPlist = item.path.replacingOccurrences(of: "'", with: "'\\''")
            let shellCmd = "cp '\(escapedSrc)' '\(escapedDst)' && /bin/launchctl \(launchctlVerb) '\(escapedPlist)' 2>/dev/null || true"
            let appleScript = "do shell script \"\(shellCmd.replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"

            var err: NSDictionary?
            NSAppleScript(source: appleScript)?.executeAndReturnError(&err)
            if let err = err {
                let msg = err["NSAppleScriptErrorMessage"] as? String ?? "未知錯誤"
                if (err["NSAppleScriptErrorNumber"] as? Int) == -128 {
                    return .init(success: false, message: "已取消（未輸入管理員密碼）。")
                }
                return .init(success: false, message: "失敗：\(msg)")
            }
            return .init(success: true, message: enable ? "已啟用。" : "已停用。")
        } else {
            // User-level: direct write + launchctl
            do {
                try newData.write(to: URL(fileURLWithPath: item.path))
            } catch {
                return .init(success: false, message: "寫入失敗：\(error.localizedDescription)")
            }

            // launchctl load/unload (best-effort — may fail if already loaded; that's OK)
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            task.arguments = [enable ? "load" : "unload", item.path]
            task.standardOutput = Pipe()
            task.standardError = Pipe()
            _ = try? task.run()
            task.waitUntilExit()
            return .init(success: true, message: enable ? "已啟用。" : "已停用。")
        }
    }
}
