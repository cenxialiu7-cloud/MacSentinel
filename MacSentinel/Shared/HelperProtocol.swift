import Foundation

// MARK: - XPC Protocol
//
// Defined in a shared file so both the helper (server side) and the main app
// (client side) link against the same Objective-C-visible protocol.
//
// All methods accept a reply closure; the helper executes them synchronously
// inside its xpc dispatch queue. Errors are bubbled back via the `error`
// reply argument (nil = success).

@objc(MacSentinelHelperProtocol)
public protocol MacSentinelHelperProtocol {

    /// Health check — returns the helper's version string.
    /// Used by the main app to verify XPC connection is healthy.
    func getVersion(reply: @escaping (String) -> Void)

    /// Delete a file/directory at the given absolute path.
    /// Performs `chflags noschg` first then `rm -rf`. Hardened: paths
    /// matching `ProtectedSystemPaths` are rejected outright.
    func deletePath(_ path: String, reply: @escaping (Bool, String?) -> Void)

    /// Unload a LaunchAgent or LaunchDaemon (`launchctl unload <plist>`).
    func unloadLaunchEntity(plistPath: String, reply: @escaping (Bool, String?) -> Void)

    /// Move a path to the user's Trash (preserves ownership). For system
    /// paths that can't be Trashed via FileManager.trashItem (which requires
    /// the file to be on the same volume and writable by the calling user),
    /// the helper performs a copy + sudo rm fallback.
    func trashPath(_ path: String,
                   userHomeDir: String,
                   reply: @escaping (Bool, String?) -> Void)
}

// MARK: - Constants

public enum MacSentinelHelperConstants {
    /// The XPC machservice name. Must match the `MachServices` key in the
    /// helper's launchd plist (configured by SMAppService).
    public static let machServiceName = "com.macsentinel.helper"

    /// Bundle ID of the privileged helper executable.
    public static let helperBundleID = "com.macsentinel.helper"

    /// LaunchDaemon plist path after SMAppService registration.
    public static let daemonPlistPath = "/Library/LaunchDaemons/com.macsentinel.helper.plist"
}

// MARK: - Path Safety (used by helper)
//
// Even when running as root, the helper refuses to touch these paths to
// prevent catastrophic damage. The main-app ProtectedPaths is a defense in
// depth; this is the helper's own gate.

public enum ProtectedSystemPaths {
    public static let neverDelete: Set<String> = [
        "/",
        "/System",
        "/usr",
        "/bin",
        "/sbin",
        "/etc",
        "/private",
        "/Applications",         // The directory itself — individual .app deletion still allowed
        "/Library",
        "/Volumes",
        "/Users",
        "/dev",
        "/var",
    ]

    public static func isSystemCritical(_ path: String) -> Bool {
        let standardized = (path as NSString).standardizingPath
        if neverDelete.contains(standardized) { return true }
        // Reject anything starting with /System/ unconditionally
        if standardized.hasPrefix("/System/") { return true }
        return false
    }
}
