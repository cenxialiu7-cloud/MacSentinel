import Foundation
import AppKit

// MARK: - PermissionService
//
// Central oracle for "what can MacSentinel actually write to right now?"
// Used by Dashboard to show a permission banner, by SafeDeleteService to
// pick the right deletion strategy, and by the App Uninstaller to detect
// macl-protected apps before queuing a deletion.

@Observable
final class PermissionService {

    static let shared = PermissionService()

    // ── Published state (read by Dashboard banner) ──
    private(set) var hasFullDiskAccess: Bool = false
    private(set) var hasPrivilegedHelper: Bool = false
    private(set) var lastChecked: Date?

    private init() {
        // Defer initial check to caller (App.init or DashboardView.task)
    }

    // MARK: - FDA detection

    /// Probe whether the current process can write into TCC-protected
    /// `~/Library/Containers/`. Uses a write/delete cycle of a unique probe
    /// file to avoid false positives from cached permissions.
    @discardableResult
    func checkFullDiskAccess() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let probeName = ".macsentinel_fda_probe_\(UUID().uuidString.prefix(8))"
        let probe = URL(fileURLWithPath: "\(home)/Library/Containers/\(probeName)")

        // Try create
        let created = FileManager.default.createFile(atPath: probe.path, contents: nil)
        if created {
            try? FileManager.default.removeItem(at: probe)
            hasFullDiskAccess = true
        } else {
            hasFullDiskAccess = false
        }
        lastChecked = Date()
        return hasFullDiskAccess
    }

    // MARK: - Privileged Helper detection

    /// Check whether the privileged XPC helper is registered + reachable.
    /// (Implementation deferred until #1.2 ships — for now we just check
    /// if the SMAppService daemon manifest exists.)
    @discardableResult
    func checkPrivilegedHelper() -> Bool {
        let helperPlist = "/Library/LaunchDaemons/com.macsentinel.helper.plist"
        hasPrivilegedHelper = FileManager.default.fileExists(atPath: helperPlist)
        return hasPrivilegedHelper
    }

    // MARK: - Re-evaluate everything

    func refresh() {
        _ = checkFullDiskAccess()
        _ = checkPrivilegedHelper()
    }

    // MARK: - User assistance — direct deep-link to System Settings

    /// Open System Settings → Privacy & Security → Full Disk Access pane.
    /// Works on macOS 13+ via the `x-apple.systempreferences` URL scheme.
    func openFullDiskAccessSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - macl xattr detection (Tier 1.4 — used by App Uninstaller)

    /// Returns true if the given file path has the `com.apple.macl`
    /// extended attribute set. This typically means the file was installed
    /// by App Store or copied by Finder, and only those tools (or processes
    /// with FDA + macl-aware deletion) can remove it cleanly.
    static func hasMACLAttribute(_ url: URL) -> Bool {
        let path = url.path
        let bufSize = path.withCString { listxattr($0, nil, 0, 0) }
        guard bufSize > 0 else { return false }
        var buf = [CChar](repeating: 0, count: bufSize)
        let actual = path.withCString { listxattr($0, &buf, bufSize, 0) }
        guard actual > 0 else { return false }
        let data = Data(bytes: buf, count: actual)
        guard let str = String(data: data, encoding: .utf8) else { return false }
        return str.split(separator: "\0").contains("com.apple.macl")
    }
}
