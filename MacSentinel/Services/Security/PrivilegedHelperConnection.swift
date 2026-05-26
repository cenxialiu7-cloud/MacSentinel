import Foundation
import ServiceManagement

// MARK: - PrivilegedHelperConnection
//
// Manages the lifecycle of the privileged helper daemon:
//   1. Register/unregister via SMAppService.daemon(plistName:)
//   2. Establish NSXPCConnection on demand
//   3. Provide a Swift-friendly async API on top of the @objc protocol
//
// The user only sees ONE permission prompt the first time the daemon is
// registered (System Settings → Login Items → Allow). Subsequent XPC
// connections are silent.

@Observable
final class PrivilegedHelperConnection {

    static let shared = PrivilegedHelperConnection()

    enum InstallStatus: String, Codable {
        case notInstalled        // SMAppService.status == .notRegistered
        case requiresApproval    // .requiresApproval — user needs to enable in Login Items
        case installed           // .enabled — ready to use
        case notFound            // Helper binary missing from bundle
    }

    private(set) var installStatus: InstallStatus = .notInstalled
    private(set) var helperVersion: String?

    private var connection: NSXPCConnection?
    private let daemonPlistName = "com.macsentinel.helper.plist"

    private init() {
        refreshStatus()
    }

    // MARK: - SMAppService lifecycle

    /// Re-read installation status. Call after UI actions or app launch.
    func refreshStatus() {
        let service = SMAppService.daemon(plistName: daemonPlistName)
        switch service.status {
        case .notRegistered:    installStatus = .notInstalled
        case .requiresApproval: installStatus = .requiresApproval
        case .enabled:          installStatus = .installed
        case .notFound:         installStatus = .notFound
        @unknown default:       installStatus = .notInstalled
        }
    }

    /// Register the helper. Shows a system prompt the first time — user
    /// must confirm in System Settings → Login Items.
    @discardableResult
    func install() throws -> InstallStatus {
        let service = SMAppService.daemon(plistName: daemonPlistName)
        try service.register()
        refreshStatus()
        return installStatus
    }

    /// Unregister the helper.
    func uninstall() throws {
        let service = SMAppService.daemon(plistName: daemonPlistName)
        try service.unregister()
        refreshStatus()
    }

    /// Open System Settings → Login Items so the user can flip the toggle.
    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // MARK: - XPC connection

    private func ensureConnection() -> NSXPCConnection? {
        if let conn = connection { return conn }
        guard installStatus == .installed else { return nil }

        let conn = NSXPCConnection(
            machServiceName: MacSentinelHelperConstants.machServiceName,
            options: .privileged
        )
        conn.remoteObjectInterface = NSXPCInterface(with: MacSentinelHelperProtocol.self)
        conn.invalidationHandler = { [weak self] in
            self?.connection = nil
        }
        conn.interruptionHandler = { [weak self] in
            self?.connection = nil
        }
        conn.resume()
        connection = conn

        // Probe version so we know it's actually responding
        Task { [weak self] in
            self?.helperVersion = await self?.getVersion()
        }
        return conn
    }

    /// Swift-friendly async API atop the @objc protocol.

    func getVersion() async -> String? {
        await withCheckedContinuation { cont in
            guard let proxy = remoteProxy(cont: cont, defaultIfNil: nil as String?) else { return }
            proxy.getVersion(reply: { cont.resume(returning: $0) })
        }
    }

    func deletePath(_ path: String) async -> (Bool, String?) {
        await withCheckedContinuation { cont in
            guard let proxy = remoteProxy(cont: cont, defaultIfNil: (false, "Helper unavailable")) else { return }
            proxy.deletePath(path, reply: { cont.resume(returning: ($0, $1)) })
        }
    }

    func unloadLaunchEntity(plistPath: String) async -> (Bool, String?) {
        await withCheckedContinuation { cont in
            guard let proxy = remoteProxy(cont: cont, defaultIfNil: (false, "Helper unavailable")) else { return }
            proxy.unloadLaunchEntity(plistPath: plistPath, reply: { cont.resume(returning: ($0, $1)) })
        }
    }

    func trashPath(_ path: String) async -> (Bool, String?) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return await withCheckedContinuation { cont in
            guard let proxy = remoteProxy(cont: cont, defaultIfNil: (false, "Helper unavailable")) else { return }
            proxy.trashPath(path, userHomeDir: home, reply: { cont.resume(returning: ($0, $1)) })
        }
    }

    // MARK: - Helpers

    private func remoteProxy<T>(cont: CheckedContinuation<T, Never>,
                                 defaultIfNil fallback: T) -> MacSentinelHelperProtocol? {
        guard let conn = ensureConnection() else {
            cont.resume(returning: fallback)
            return nil
        }
        guard let proxy = conn.remoteObjectProxyWithErrorHandler({ [weak self] err in
            NSLog("[PrivilegedHelperConnection] XPC error: \(err.localizedDescription)")
            self?.connection?.invalidate()
            self?.connection = nil
            cont.resume(returning: fallback)
        }) as? MacSentinelHelperProtocol else {
            cont.resume(returning: fallback)
            return nil
        }
        return proxy
    }
}
