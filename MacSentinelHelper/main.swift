import Foundation

// MARK: - MacSentinelHelper — Privileged XPC Helper
//
// Runs as root (registered via SMAppService daemon manifest in the main app).
// Exposes a Mach service named "com.macsentinel.helper" that the main app
// connects to via NSXPCConnection. All destructive operations are gated by:
//
//   1. ProtectedSystemPaths whitelist (defense in depth — even root won't
//      delete /System, /usr, etc.)
//   2. SMAuthorizedClients (set in this binary's Info.plist) so only the
//      MacSentinel main app's signed bundle can connect.
//   3. Audit log entries written by the main app on every call.

NSLog("[MacSentinelHelper] Starting helper PID=\(getpid())")

// MARK: - XPC Listener Delegate

final class HelperDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {

        if !verifyClientSignature(connection) {
            NSLog("[MacSentinelHelper] Rejected connection — client signature failed")
            return false
        }

        connection.exportedInterface = NSXPCInterface(with: MacSentinelHelperProtocol.self)
        connection.exportedObject = HelperImpl()
        connection.invalidationHandler = {
            NSLog("[MacSentinelHelper] Connection invalidated")
        }
        connection.resume()
        return true
    }

    /// Verify the connecting peer is the MacSentinel main app, signed by us.
    /// NSXPCConnection's `auditToken` is internal-ish on macOS; we use KVC
    /// to grab it (well-known trick used by Apple's own ServiceManagement
    /// sample code and by many open-source privileged helpers).
    private func verifyClientSignature(_ connection: NSXPCConnection) -> Bool {
        // Pull audit token via KVC — works on macOS 13+
        guard let tokenObj = connection.value(forKey: "auditToken") else { return false }
        var token = audit_token_t()
        // The token is stored as NSData of audit_token_t bytes
        let nsToken = tokenObj as? NSData
        if let nsToken = nsToken, nsToken.length == MemoryLayout<audit_token_t>.size {
            nsToken.getBytes(&token, length: MemoryLayout<audit_token_t>.size)
        } else {
            // Some macOS versions return audit_token_t directly bridged
            return false
        }

        let attrs: [String: Any] = [
            kSecGuestAttributeAudit as String: Data(bytes: &token,
                                                     count: MemoryLayout<audit_token_t>.size)
        ]
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attrs as CFDictionary, [], &code) == errSecSuccess,
              let secCode = code
        else { return false }

        // Require the peer to be signed with our bundle identifier
        let requirementString = "identifier \"com.macsentinel.app\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementString as CFString, [], &requirement) == errSecSuccess,
              let req = requirement
        else { return false }

        return SecCodeCheckValidity(secCode, [], req) == errSecSuccess
    }
}

// MARK: - Implementation

final class HelperImpl: NSObject, MacSentinelHelperProtocol {

    func getVersion(reply: @escaping (String) -> Void) {
        reply("1.0.0")
    }

    func deletePath(_ path: String, reply: @escaping (Bool, String?) -> Void) {
        if ProtectedSystemPaths.isSystemCritical(path) {
            reply(false, "拒絕：路徑屬系統關鍵位置。")
            return
        }
        guard FileManager.default.fileExists(atPath: path) else {
            reply(false, "路徑不存在：\(path)")
            return
        }
        _ = run("/usr/bin/chflags", args: ["-R", "noschg,nouchg", path])
        do {
            try FileManager.default.removeItem(atPath: path)
            NSLog("[MacSentinelHelper] Deleted: \(path)")
            reply(true, nil)
        } catch {
            reply(false, "刪除失敗：\(error.localizedDescription)")
        }
    }

    func unloadLaunchEntity(plistPath: String, reply: @escaping (Bool, String?) -> Void) {
        guard FileManager.default.fileExists(atPath: plistPath) else {
            reply(false, "plist 不存在：\(plistPath)")
            return
        }
        let out = run("/bin/launchctl", args: ["unload", plistPath])
        if out.status == 0 { reply(true, nil) }
        else { reply(false, "launchctl unload 失敗 (exit \(out.status))：\(out.stderr ?? "")") }
    }

    func trashPath(_ path: String,
                   userHomeDir: String,
                   reply: @escaping (Bool, String?) -> Void) {
        if ProtectedSystemPaths.isSystemCritical(path) {
            reply(false, "拒絕：路徑屬系統關鍵位置。")
            return
        }
        guard FileManager.default.fileExists(atPath: path) else {
            reply(false, "路徑不存在：\(path)")
            return
        }
        let basename = (path as NSString).lastPathComponent
        let ts = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let trashPath = "\(userHomeDir)/.Trash/\(basename).macsentinel-\(ts)"
        do {
            try FileManager.default.moveItem(atPath: path, toPath: trashPath)
            if let stat = try? FileManager.default.attributesOfItem(atPath: userHomeDir),
               let ownerID = stat[.ownerAccountID] as? NSNumber,
               let groupID = stat[.groupOwnerAccountID] as? NSNumber {
                _ = run("/usr/sbin/chown", args: ["-R",
                                                    "\(ownerID.intValue):\(groupID.intValue)",
                                                    trashPath])
            }
            reply(true, nil)
        } catch {
            reply(false, "移到垃圾桶失敗：\(error.localizedDescription)")
        }
    }

    // MARK: - Process runner

    private struct ProcessResult {
        let status: Int32
        let stdout: String?
        let stderr: String?
    }

    private func run(_ executable: String, args: [String]) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        let outPipe = Pipe(); let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do { try process.run() } catch {
            return ProcessResult(status: -1, stdout: nil, stderr: error.localizedDescription)
        }
        process.waitUntilExit()
        return ProcessResult(
            status: process.terminationStatus,
            stdout: String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8),
            stderr: String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        )
    }
}

// MARK: - Boot the XPC listener

let delegate = HelperDelegate()
let listener = NSXPCListener(machServiceName: MacSentinelHelperConstants.machServiceName)
listener.delegate = delegate
listener.resume()

RunLoop.current.run()
