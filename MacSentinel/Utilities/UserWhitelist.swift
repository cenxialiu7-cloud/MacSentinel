//
//  UserWhitelist.swift
//  MacSentinel
//
//  User-defined "never scan" list. Persisted to UserDefaults under
//  the key `userScanWhitelist`. Used by CacheScanner, LargeFileScanner
//  and DuplicateScanner to filter out paths the user has explicitly
//  marked as off-limits.
//
//  This is independent from ProtectedPaths (system-level safety rules)
//  — that one is hard-coded, this one is user-editable.
//

import Foundation
import Observation

@MainActor
@Observable
final class UserWhitelist {

    static let shared = UserWhitelist()

    /// Sorted list of canonical absolute paths.
    private(set) var paths: [String] = []

    private let defaultsKey = "userScanWhitelist"

    private init() {
        load()
    }

    // MARK: - Public API

    /// Returns true if `path` exactly matches any whitelisted entry, or sits
    /// underneath any whitelisted directory. Comparison is case-insensitive on
    /// macOS HFS+ / APFS default (case-insensitive) semantics.
    nonisolated func isWhitelisted(_ path: String) -> Bool {
        let canon = (path as NSString).standardizingPath.lowercased()
        // Snapshot current paths outside main actor for thread safety
        let snapshot = MainActor.assumeIsolated { paths }
        for entry in snapshot {
            let e = entry.lowercased()
            if canon == e || canon.hasPrefix(e.hasSuffix("/") ? e : e + "/") {
                return true
            }
        }
        return false
    }

    @MainActor
    func add(_ rawPath: String) {
        let canon = (rawPath as NSString).standardizingPath
        guard !canon.isEmpty, !paths.contains(canon) else { return }
        paths.append(canon)
        paths.sort()
        persist()
    }

    @MainActor
    func remove(_ path: String) {
        paths.removeAll { $0 == path }
        persist()
    }

    @MainActor
    func reset() {
        paths.removeAll()
        persist()
    }

    // MARK: - Persistence

    private func load() {
        let arr = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        paths = arr.sorted()
    }

    private func persist() {
        UserDefaults.standard.set(paths, forKey: defaultsKey)
    }
}
