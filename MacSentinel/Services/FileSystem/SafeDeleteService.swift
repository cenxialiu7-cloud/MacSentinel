import Foundation

// MARK: - Safe Delete Service (multi-tier fallback)
//
// Every destructive operation funnels through this actor. Goals:
//   1. ProtectedPaths must always be enforced — no path can bypass.
//   2. Use the most-direct mechanism that will succeed for a given path.
//   3. Surface clear, actionable error categories when nothing works.
//
// Delete strategy (cascading, first-success wins):
//
//     ┌─────────────────────────────────────────────────────────────┐
//     │ 1. Direct FileManager.trashItem                              │
//     │    Works for: user-owned files NOT under TCC/macl restrictions │
//     ├─────────────────────────────────────────────────────────────┤
//     │ 2. osascript-via-Finder                                      │
//     │    Works for: files with com.apple.macl ACL, files in        │
//     │    ~/Library/Containers/* when Finder has FDA                │
//     ├─────────────────────────────────────────────────────────────┤
//     │ 3. Privileged Helper (XPC) — when registered                 │
//     │    Works for: /Library/LaunchAgents, /Library/Extensions,    │
//     │    other root-owned paths                                    │
//     ├─────────────────────────────────────────────────────────────┤
//     │ 4. Report failure with category + suggestion                 │
//     │    → caller decides whether to ask the user for FDA / sudo   │
//     └─────────────────────────────────────────────────────────────┘

actor SafeDeleteService {

    static let shared = SafeDeleteService()

    enum DeletionMethod: String, Codable {
        case direct           // FileManager.trashItem
        case finder           // osascript via Finder ACL
        case xpcHelper        // privileged helper (future)
        case skipped          // dry-run or protected
    }

    enum FailureCategory: String, Codable {
        case tccBlocked
        case rootRequired
        case maclACL
        case protectedByPolicy
        case fileNotFound
        case unknown
    }

    struct DeletionFailure {
        let url: URL
        let error: Error
        let category: FailureCategory
        let suggestion: String
    }

    struct DeletionResult {
        var deleted:    [(URL, UInt64, DeletionMethod)] = []
        var skipped:    [URL]              = []   // ProtectedPaths
        var failed:     [(URL, Error)]     = []
        var failures:   [DeletionFailure]  = []   // classified failures
        var wouldDelete:[(URL, UInt64)]    = []   // dry-run preview

        var totalDeletedBytes: UInt64 { deleted.reduce(0) { $0 + $1.1 } }
        var totalWouldDeleteBytes: UInt64 { wouldDelete.reduce(0) { $0 + $1.1 } }
    }

    /// Public entry point. Tries each tier until one succeeds.
    ///
    /// `policy` controls the strictness of ProtectedPaths:
    ///   • `.aiSafe` (default) — block user content roots (Documents, Desktop,
    ///     Downloads, Pictures, Movies, Music, Public). Use for any caller
    ///     that doesn't represent a human directly clicking the path
    ///     (MCP tools, batch cleaners, scheduled scans).
    ///   • `.userExplicit` — the human picked the path in the GUI and can
    ///     see what's queued. Allow user-content-roots; still hard-block
    ///     keychain / mail / safari / iCloud / Photos library / system paths.
    func remove(items: [URL],
                dryRun: Bool = false,
                policy: ProtectedPaths.DeletionPolicy = .aiSafe) async -> DeletionResult {
        var result = DeletionResult()
        let fm = FileManager.default

        for url in items {
            // 1. ProtectedPaths gate (immutable)
            guard !ProtectedPaths.isProtected(url, policy: policy) else {
                result.skipped.append(url)
                continue
            }

            // 2. Existence
            guard fm.fileExists(atPath: url.path) else { continue }

            let size = directorySize(url)

            if dryRun {
                result.wouldDelete.append((url, size))
                continue
            }

            // 3. Multi-tier delete attempt
            let outcome = await attemptDelete(url: url)
            switch outcome {
            case .success(let method):
                result.deleted.append((url, size, method))
                await AuditLog.shared.record(.deletion(url: url, sizeBytes: size))
            case .failure(let err, let category, let suggestion):
                result.failed.append((url, err))
                result.failures.append(.init(
                    url: url, error: err,
                    category: category, suggestion: suggestion
                ))
            }
        }
        return result
    }

    /// Remove contents of a directory (not the directory itself).
    func removeContents(of directory: URL,
                        dryRun: Bool = false,
                        policy: ProtectedPaths.DeletionPolicy = .aiSafe) async -> DeletionResult {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return DeletionResult() }
        return await remove(items: contents, dryRun: dryRun, policy: policy)
    }

    func sizeOfItems(_ urls: [URL]) -> UInt64 {
        urls.reduce(0) { $0 + directorySize($1) }
    }

    // MARK: - Multi-tier attempt

    private enum AttemptResult {
        case success(DeletionMethod)
        case failure(Error, FailureCategory, String)
    }

    private func attemptDelete(url: URL) async -> AttemptResult {
        // ── Tier 1: Direct FileManager ──
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            return .success(.direct)
        } catch let directErr {
            // Direct failed. Decide what to try next.

            // ── Tier 2: osascript Finder (handles com.apple.macl + sometimes TCC) ──
            if shouldTryFinder(url: url, directError: directErr) {
                if await trashViaFinder(url: url) {
                    return .success(.finder)
                }
            }

            // ── Tier 3: XPC Helper (future) ──
            // if isHelperRegistered() && shouldTryHelper(url: url) {
            //     if await trashViaHelper(url: url) { return .success(.xpcHelper) }
            // }

            // ── Tier 4: Classify + report ──
            let (cat, suggestion) = classifyFailure(url: url, error: directErr)
            return .failure(directErr, cat, suggestion)
        }
    }

    /// Should we try the Finder ACL path for this URL?
    private func shouldTryFinder(url: URL, directError: Error) -> Bool {
        // Always worth trying Finder if:
        //   - URL has com.apple.macl xattr (App Store / Finder-installed)
        //   - URL is in ~/Library/Containers/* (TCC)
        //   - URL is in ~/Library/Group Containers/* (TCC for some)
        //   - URL is /Applications/*.app (often macl-protected)
        let path = url.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix("\(home)/Library/Containers/") ||
           path.hasPrefix("\(home)/Library/Group Containers/") ||
           path.hasPrefix("/Applications/") {
            return true
        }
        return hasMACLAttribute(url: url)
    }

    private func trashViaFinder(url: URL) async -> Bool {
        let escaped = url.path.replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Finder\" to delete POSIX file \"\(escaped)\""
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.launchPath = "/usr/bin/osascript"
                process.arguments = ["-e", script]
                let out = Pipe(); let err = Pipe()
                process.standardOutput = out
                process.standardError = err
                do { try process.run() } catch {
                    cont.resume(returning: false); return
                }
                process.waitUntilExit()
                // Success if: exit 0 AND original path no longer exists
                let succeeded = process.terminationStatus == 0 &&
                    !FileManager.default.fileExists(atPath: url.path)
                cont.resume(returning: succeeded)
            }
        }
    }

    private func hasMACLAttribute(url: URL) -> Bool {
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

    private func classifyFailure(url: URL, error: Error) -> (FailureCategory, String) {
        let path = url.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let ns = error as NSError

        if !FileManager.default.fileExists(atPath: path) {
            return (.fileNotFound, "檔案在嘗試刪除前已不存在。")
        }
        if path.hasPrefix("/Library/") || path.hasPrefix("/System/") {
            return (.rootRequired,
                    "此路徑需要 root 權限。建議：(1) 在 Terminal 用 sudo 處理，或 (2) 等 MacSentinel Privileged Helper 實作完成。")
        }
        if path.hasPrefix("\(home)/Library/Containers/") ||
           path.hasPrefix("\(home)/Library/Group Containers/") {
            return (.tccBlocked,
                    "macOS TCC 保護此 Container。請至「系統設定 → 隱私權與安全性 → 完整磁碟取用權」授予 MacSentinel.app（或啟動 MacSentinel 的進程，如 Claude.app / Terminal.app）FDA 權限後再試。")
        }
        if hasMACLAttribute(url: url) {
            return (.maclACL,
                    "此檔案帶有 com.apple.macl ACL（App Store 或 Finder 安裝）。MacSentinel 已嘗試 osascript Finder 但失敗 — 請改用 Finder 手動拖到垃圾桶。")
        }
        if ns.code == 257 || ns.code == 513 {
            return (.unknown,
                    "權限不足。原始錯誤：\(error.localizedDescription)")
        }
        return (.unknown, "未知失敗：\(error.localizedDescription)")
    }

    // MARK: - Helpers

    private func directorySize(_ url: URL) -> UInt64 {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path) else { return 0 }

        if let size = attrs[.size] as? UInt64,
           (attrs[.type] as? FileAttributeType) == .typeRegular {
            return size
        }

        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return 0 }

        var total: UInt64 = 0
        for case let fileURL as URL in enumerator {
            if let res = try? fileURL.resourceValues(forKeys: [.totalFileSizeKey]),
               let size = res.totalFileSize {
                total += UInt64(size)
            }
        }
        return total
    }
}
