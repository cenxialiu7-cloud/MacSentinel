//
//  UserWhitelist.swift
//  MacSentinel
//
//  User-defined "never scan" list. Persisted to UserDefaults under the key
//  `userScanWhitelist`. Used by CacheScanner, LargeFileScanner,
//  DuplicateScanner and DiskHotspotService to filter out paths the user has
//  explicitly marked as off-limits.
//
//  Thread-safe: all accessors are guarded by an internal NSLock so any
//  background scanner worker can call `isWhitelisted(_:)` without ever
//  touching the main actor. UI consumers should re-read `snapshot()` after
//  calling a mutator.
//

import Foundation

final class UserWhitelist: @unchecked Sendable {

    static let shared = UserWhitelist()

    private let lock = NSLock()
    private var _paths: [String] = []
    private let defaultsKey = "userScanWhitelist"

    private init() { loadFromDefaults() }

    // MARK: - Reads

    /// Return a sorted snapshot of whitelisted paths. Safe from any thread.
    func snapshot() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return _paths
    }

    /// Return true if `path` matches any whitelisted entry exactly, or sits
    /// underneath one. Safe from any thread (scanner workers call this).
    func isWhitelisted(_ path: String) -> Bool {
        let canon = (path as NSString).standardizingPath.lowercased()
        lock.lock()
        let pathsCopy = _paths
        lock.unlock()
        for entry in pathsCopy {
            let e = entry.lowercased()
            if canon == e || canon.hasPrefix(e.hasSuffix("/") ? e : e + "/") {
                return true
            }
        }
        return false
    }

    // MARK: - Mutators

    func add(_ rawPath: String) {
        let canon = (rawPath as NSString).standardizingPath
        guard !canon.isEmpty else { return }
        lock.lock()
        if !_paths.contains(canon) {
            _paths.append(canon)
            _paths.sort()
        }
        lock.unlock()
        persist()
    }

    func remove(_ path: String) {
        lock.lock()
        _paths.removeAll { $0 == path }
        lock.unlock()
        persist()
    }

    func reset() {
        lock.lock()
        _paths.removeAll()
        lock.unlock()
        persist()
    }

    // MARK: - Persistence

    private func loadFromDefaults() {
        let arr = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        lock.lock(); _paths = arr.sorted(); lock.unlock()
    }

    private func persist() {
        lock.lock(); let copy = _paths; lock.unlock()
        UserDefaults.standard.set(copy, forKey: defaultsKey)
    }
}
