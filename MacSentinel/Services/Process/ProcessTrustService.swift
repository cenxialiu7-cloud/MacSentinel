import Foundation
import Security

// MARK: - ProcessTrustService
//
// Evaluates the trust level of a running process by inspecting the code
// signature of its on-disk binary (via Security.framework). Static analysis
// only — does not need privileged task ports, works for any process whose
// path we can read.
//
// Caching: keyed by (path, cdhash) so re-evaluating an already-classified
// binary is O(1).

final class ProcessTrustService {

    static let shared = ProcessTrustService()
    private init() {}

    // MARK: - Cache

    private struct CacheKey: Hashable { let path: String }
    private var cache: [CacheKey: ProcessTrustInfo] = [:]
    private let cacheQueue = DispatchQueue(label: "macsentinel.trust.cache",
                                            attributes: .concurrent)

    // MARK: - Public API

    /// Evaluate the trust info for a single process (by PID + path + name).
    /// Path-based static analysis — does NOT require privileged access.
    func evaluate(pid: Int32, path: String, name: String) -> ProcessTrustInfo {
        let key = CacheKey(path: path)
        if let cached = readCache(key) { return cached.with(pid: pid) }

        let info = doEvaluate(pid: pid, path: path, name: name)
        writeCache(key, info)
        return info
    }

    /// Evaluate a list of processes in parallel, with a bounded fan-out.
    ///
    /// `SecStaticCodeCheckValidity` is CPU-bound and synchronous; spawning
    /// unlimited tasks does not help and can starve the cooperative thread
    /// pool. We cap concurrent evaluations to `maxConcurrent` (default = CPU
    /// count), and process the rest as each slot completes.
    func evaluateAll(_ processes: [ProcessInfo],
                     maxConcurrent: Int = max(2, Foundation.ProcessInfo.processInfo.activeProcessorCount)) async -> [ProcessTrustInfo] {
        await withTaskGroup(of: ProcessTrustInfo.self) { group in
            var iter = processes.makeIterator()
            var inflight = 0
            var results: [ProcessTrustInfo] = []
            results.reserveCapacity(processes.count)

            func enqueueNext() -> Bool {
                guard let proc = iter.next() else { return false }
                group.addTask { [weak self] in
                    self?.evaluate(pid: proc.id, path: proc.executablePath, name: proc.name)
                        ?? ProcessTrustInfo.unavailable(pid: proc.id, path: proc.executablePath, name: proc.name)
                }
                inflight += 1
                return true
            }

            for _ in 0..<maxConcurrent { if !enqueueNext() { break } }

            while inflight > 0 {
                if let info = await group.next() {
                    results.append(info)
                    inflight -= 1
                    _ = enqueueNext()
                }
            }
            return results
        }
    }

    /// Pre-warm the cache in the background. Call once at app launch so
    /// the first user-visible scan returns instantly.
    func warmCache() {
        Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            let snap = await ProcessSnapshotService.shared.snapshotOnce()
            _ = await self.evaluateAll(Array(snap.prefix(150)),
                                       maxConcurrent: 2)
        }
    }

    private func readCache(_ key: CacheKey) -> ProcessTrustInfo? {
        cacheQueue.sync { cache[key] }
    }
    private func writeCache(_ key: CacheKey, _ info: ProcessTrustInfo) {
        cacheQueue.async(flags: .barrier) { self.cache[key] = info }
    }

    // MARK: - Core evaluation

    private func doEvaluate(pid: Int32, path: String, name: String) -> ProcessTrustInfo {
        var reasons: [String] = []

        // 0. Existence check — kernel_task, ATS daemons etc. have empty paths
        guard !path.isEmpty else {
            return ProcessTrustInfo(
                pid: pid, executablePath: path, processName: name,
                trustLevel: pidIsKernelTask(pid) ? .l5_appleSystem : .l1_unsigned,
                isSignatureValid: false, isAdHoc: false,
                teamIdentifier: nil, signingIdentifier: nil,
                authorityChain: [], isNotarized: false, isHardenedRuntime: false,
                highRiskEntitlements: [], allEntitlements: [], cdHash: nil,
                isPathSuspicious: false, isImpersonatingSystem: false,
                reasons: pidIsKernelTask(pid)
                    ? ["macOS kernel task (PID 0)"]
                    : ["Cannot resolve executable path"]
            )
        }

        // 1. Build a SecStaticCode for the on-disk binary
        let pathURL = URL(fileURLWithPath: resolveBundlePath(path))
        var staticCode: SecStaticCode?
        let createResult = SecStaticCodeCreateWithPath(pathURL as CFURL, [], &staticCode)
        guard createResult == errSecSuccess, let code = staticCode else {
            reasons.append("Cannot create SecStaticCode for path")
            return ProcessTrustInfo(
                pid: pid, executablePath: path, processName: name,
                trustLevel: .l1_unsigned,
                isSignatureValid: false, isAdHoc: false,
                teamIdentifier: nil, signingIdentifier: nil,
                authorityChain: [], isNotarized: false, isHardenedRuntime: false,
                highRiskEntitlements: [], allEntitlements: [], cdHash: nil,
                isPathSuspicious: isPathSuspicious(path),
                isImpersonatingSystem: false,
                reasons: reasons
            )
        }

        // 2. Validate signature
        let validateFlags: SecCSFlags = SecCSFlags(rawValue: 0)  // kSecCSDefaultFlags = 0
        let validateResult = SecStaticCodeCheckValidity(code, validateFlags, nil)
        let isValid = (validateResult == errSecSuccess)
        if !isValid {
            reasons.append("Signature validation failed (\(validateResult))")
        }

        // 3. Pull signing information
        var infoDict: CFDictionary?
        // SecCS info flag bits (from <Security/SecCode.h>):
        //   kSecCSSigningInformation    = 0x2
        //   kSecCSRequirementInformation = 0x4
        //   kSecCSInternalInformation   = 0x1
        let infoFlags = SecCSFlags(rawValue: 0x2 | 0x4 | 0x1)
        let infoResult = SecCodeCopySigningInformation(code, infoFlags, &infoDict)
        let info = (infoResult == errSecSuccess) ? (infoDict as? [String: Any] ?? [:]) : [:]

        // Flags — raw bit values from <Security/CSCommon.h>:
        //   kSecCodeSignatureAdhoc   = 0x0000002
        //   kSecCodeSignatureRuntime = 0x0010000  (Hardened Runtime)
        // Tolerate either UInt32 or NSNumber encoding (varies by macOS version).
        let flags: UInt32 = {
            if let f = info[kSecCodeInfoFlags as String] as? UInt32 { return f }
            if let n = info[kSecCodeInfoFlags as String] as? NSNumber { return n.uint32Value }
            return 0
        }()
        let isAdHoc      = (flags & 0x0000002) != 0
        let isHardenedRT = (flags & 0x0010000) != 0

        // Team ID
        let teamID = info[kSecCodeInfoTeamIdentifier as String] as? String
        // Identifier (typically bundle ID for app bundles)
        let signIdent = info[kSecCodeInfoIdentifier as String] as? String

        // Authority chain
        let authorities = (info["certificates"] as? [SecCertificate])
            ?? (info[kSecCodeInfoCertificates as String] as? [SecCertificate]) ?? []
        let authNames: [String] = authorities.map { cert in
            var name: CFString?
            SecCertificateCopyCommonName(cert, &name)
            return name as String? ?? "(unnamed)"
        }

        // cdhash
        let cdHashData = info[kSecCodeInfoUnique as String] as? Data
        let cdHashHex  = cdHashData?.map { String(format: "%02x", $0) }.joined()

        // Notarization check
        let isNotarized = checkNotarization(staticCode: code, info: info)

        // Entitlements
        let (allEnt, riskyEnt) = extractEntitlements(info: info)
        if !riskyEnt.isEmpty {
            reasons.append("Holds high-risk entitlements: \(riskyEnt.joined(separator: ", "))")
        }

        // Heuristics
        let pathSuspicious = isPathSuspicious(path)
        if pathSuspicious { reasons.append("Running from suspicious path") }
        let isImpersonating = isImpersonatingSystem(name: name, path: path)
        if isImpersonating { reasons.append("Process name resembles a system process but path is non-standard") }

        // ─── Trust level decision ─────────────────────────────────────────
        let level = decideTrustLevel(
            isValid: isValid,
            isAdHoc: isAdHoc,
            teamID: teamID,
            authorityChain: authNames,
            path: path,
            isNotarized: isNotarized,
            isImpersonating: isImpersonating
        )

        if level == .l5_appleSystem { reasons.insert("Signed by Apple, system path", at: 0) }
        else if level == .l4_notarizedThird {
            reasons.insert("Developer ID + notarized: \(teamID ?? "?")", at: 0)
        }

        return ProcessTrustInfo(
            pid: pid, executablePath: path, processName: name,
            trustLevel: level,
            isSignatureValid: isValid,
            isAdHoc: isAdHoc,
            teamIdentifier: teamID,
            signingIdentifier: signIdent,
            authorityChain: authNames,
            isNotarized: isNotarized,
            isHardenedRuntime: isHardenedRT,
            highRiskEntitlements: riskyEnt,
            allEntitlements: allEnt,
            cdHash: cdHashHex,
            isPathSuspicious: pathSuspicious,
            isImpersonatingSystem: isImpersonating,
            reasons: reasons
        )
    }

    // MARK: - Trust level decision

    private func decideTrustLevel(
        isValid: Bool,
        isAdHoc: Bool,
        teamID: String?,
        authorityChain: [String],
        path: String,
        isNotarized: Bool,
        isImpersonating: Bool
    ) -> ProcessTrustLevel {

        // L1 outright
        if !isValid && !isAppleSystemPath(path) { return .l1_unsigned }
        if isImpersonating { return .l1_unsigned }

        // L5: Apple Software Signing
        let isAppleAuthority = authorityChain.contains { name in
            name.contains("Software Signing") ||
            name.contains("Apple Mac OS Application Signing") ||
            name.contains("Apple iPhone OS Application Signing")
        }
        let hasAppleRoot = authorityChain.contains { $0.contains("Apple Root") }
        if isAppleAuthority && isAppleSystemPath(path) { return .l5_appleSystem }

        // Strong fallback: if the cert chain has BOTH Apple Software Signing AND
        // Apple Root CA, that's a chain only Apple can produce. This covers
        // Apple binaries that live in unexpected paths (cryptex mounts, future
        // SIP-protected locations) without needing the path heuristic to keep up.
        if isAppleAuthority && hasAppleRoot { return .l5_appleSystem }

        // L2: ad-hoc
        if isAdHoc { return .l2_adhocOrSelfSigned }

        // L1: no TeamID and not ad-hoc and not Apple
        guard let _ = teamID else {
            return .l2_adhocOrSelfSigned   // signed but no team — usually self-signed dev builds
        }

        // L4 vs L3 based on notarization
        return isNotarized ? .l4_notarizedThird : .l3_signedNotNotarized
    }

    // MARK: - Helpers

    /// On macOS, `proc_pidpath` for an app process returns the inner Mach-O
    /// path like /Applications/Foo.app/Contents/MacOS/Foo. For Security.framework
    /// to see the full app signature (including resource sealing), we usually
    /// want the .app bundle path. Roll back to bundle if applicable.
    private func resolveBundlePath(_ exec: String) -> String {
        if let range = exec.range(of: ".app/Contents/MacOS/") {
            return String(exec[..<range.lowerBound]) + ".app"
        }
        return exec
    }

    /// Apple Silicon's kernel runs as PID 0 with no readable path.
    private func pidIsKernelTask(_ pid: Int32) -> Bool { pid == 0 }

    private func isAppleSystemPath(_ path: String) -> Bool {
        path.hasPrefix("/System/") ||
        path.hasPrefix("/usr/libexec/") ||
        path.hasPrefix("/usr/sbin/") ||
        path.hasPrefix("/usr/bin/") ||
        path.hasPrefix("/sbin/") ||
        path.hasPrefix("/bin/") ||
        path.hasPrefix("/private/var/db/com.apple.") ||
        // macOS 13+ moves several Apple system services here (XProtect,
        // CoreDevice/remotepairingd, etc.). These are SIP-protected mounts
        // of Apple's "cryptex" content — same trust level as /System.
        path.hasPrefix("/Library/Apple/System/") ||
        path.hasPrefix("/Library/Apple/usr/")
    }

    private func isPathSuspicious(_ path: String) -> Bool {
        // Apple/Homebrew/standard paths are fine
        if isAppleSystemPath(path) { return false }
        if path.hasPrefix("/Applications/") { return false }
        if path.hasPrefix("/opt/homebrew/") || path.hasPrefix("/usr/local/") { return false }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix("\(home)/Applications/") { return false }
        if path.hasPrefix("\(home)/Library/Application Support/") { return false }  // dev tools
        if path.hasPrefix("\(home)/.cargo/") { return false }    // Rust binaries
        if path.hasPrefix("\(home)/.nvm/")   { return false }
        if path.hasPrefix("\(home)/.rbenv/") { return false }

        // Outright suspicious
        return path.hasPrefix("/tmp/") ||
               path.hasPrefix("/private/tmp/") ||
               path.hasPrefix("/Users/Shared/") ||
               path.contains("/var/folders/")
    }

    /// Names of well-known system processes that should ONLY come from system paths.
    private static let systemProcessNames: Set<String> = [
        "kernel_task", "launchd", "WindowServer", "loginwindow", "Dock", "Finder",
        "SystemUIServer", "coreaudiod", "bluetoothd", "mds", "mds_stores",
        "mdworker", "mdworker_shared", "cfprefsd", "distnoted", "UserEventAgent",
        "securityd", "trustd", "nsurlsessiond", "apsd", "syslogd",
        "opendirectoryd", "powerd", "hidd", "configd", "notifyd", "logd",
        "runningboardd", "backboardd", "ControlCenter", "NotificationCenter",
        "Spotlight", "TextInputMenuAgent", "appleaccountd", "AppleIDAuthAgent",
    ]

    private func isImpersonatingSystem(name: String, path: String) -> Bool {
        guard ProcessTrustService.systemProcessNames.contains(name) else { return false }
        return !isAppleSystemPath(path)
    }

    /// Cached "notarized" SecRequirement — building it on every call adds up
    /// across hundreds of processes.
    private static let notarizedRequirement: SecRequirement? = {
        var req: SecRequirement?
        let str = "anchor apple generic and notarized" as CFString
        guard SecRequirementCreateWithString(str, [], &req) == errSecSuccess else { return nil }
        return req
    }()

    /// Check if notarization ticket is present. Fast path: trust the
    /// `notarized` info field set by recent macOS versions. The slow fallback
    /// (full SecStaticCodeCheckValidity against the notarized requirement)
    /// is opt-in only — used when the info field is missing AND the caller
    /// asked for deep verification. Batch evaluation skips it.
    private func checkNotarization(staticCode: SecStaticCode,
                                    info: [String: Any],
                                    deep: Bool = false) -> Bool {
        if let n = info["notarized"] as? Bool { return n }
        guard deep, let req = ProcessTrustService.notarizedRequirement else { return false }
        let status = SecStaticCodeCheckValidity(staticCode, SecCSFlags(rawValue: 0), req)
        return status == errSecSuccess
    }

    // MARK: - Entitlements

    /// List of entitlements considered high-risk if present on a 3rd-party app.
    private static let highRiskEntitlements: Set<String> = [
        "com.apple.security.cs.disable-library-validation",
        "com.apple.security.cs.allow-unsigned-executable-memory",
        "com.apple.security.cs.allow-dyld-environment-variables",
        "com.apple.security.cs.allow-jit",
        "com.apple.security.cs.disable-executable-page-protection",
        "com.apple.security.get-task-allow",
        "com.apple.developer.endpoint-security.client",
        "com.apple.developer.system-extension.install",
    ]

    private func extractEntitlements(info: [String: Any]) -> (all: [String], risky: [String]) {
        let entDict = (info[kSecCodeInfoEntitlementsDict as String] as? [String: Any]) ?? [:]
        let allKeys = Array(entDict.keys).sorted()
        let risky = allKeys.filter { ProcessTrustService.highRiskEntitlements.contains($0) }
        // Also flag any com.apple.private.* — should NEVER be on third-party apps
        let privateUse = allKeys.filter { $0.hasPrefix("com.apple.private.") }
        return (all: allKeys, risky: risky + privateUse)
    }
}

// MARK: - Helpers

extension ProcessTrustInfo {
    /// Return a copy with a different PID (cached info is path-based, so reuse).
    func with(pid: Int32) -> ProcessTrustInfo {
        ProcessTrustInfo(
            pid: pid, executablePath: executablePath, processName: processName,
            trustLevel: trustLevel, isSignatureValid: isSignatureValid,
            isAdHoc: isAdHoc, teamIdentifier: teamIdentifier,
            signingIdentifier: signingIdentifier, authorityChain: authorityChain,
            isNotarized: isNotarized, isHardenedRuntime: isHardenedRuntime,
            highRiskEntitlements: highRiskEntitlements, allEntitlements: allEntitlements,
            cdHash: cdHash, isPathSuspicious: isPathSuspicious,
            isImpersonatingSystem: isImpersonatingSystem, reasons: reasons
        )
    }

    /// Fallback for processes we couldn't analyze.
    static func unavailable(pid: Int32, path: String, name: String) -> ProcessTrustInfo {
        ProcessTrustInfo(
            pid: pid, executablePath: path, processName: name,
            trustLevel: .l2_adhocOrSelfSigned,
            isSignatureValid: false, isAdHoc: false,
            teamIdentifier: nil, signingIdentifier: nil,
            authorityChain: [], isNotarized: false, isHardenedRuntime: false,
            highRiskEntitlements: [], allEntitlements: [], cdHash: nil,
            isPathSuspicious: false, isImpersonatingSystem: false,
            reasons: ["Trust evaluation unavailable"]
        )
    }
}
