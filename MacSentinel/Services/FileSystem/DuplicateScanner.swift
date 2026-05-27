//
//  DuplicateScanner.swift
//  MacSentinel
//
//  Three-stage duplicate file scanner ported from MacCleanerPro:
//    1. Group files by exact size (cheap O(N) walk)
//    2. Within each size-group, hash the first 4KB (quick filter)
//    3. Within each quick-hash collision, hash the full file (SHA-256)
//
//  Stage 3 streams the file in 1 MB chunks inside an autoreleasepool to
//  keep peak memory bounded even when scanning very large files.
//

import Foundation
import CryptoKit

// MARK: - Public model

/// A set of files whose contents are byte-identical.
struct DuplicateGroup: Identifiable {
    let id = UUID()
    /// SHA-256 of the file contents — also serves as the canonical group key.
    let contentHash: String
    let sizeBytes: UInt64
    /// Sorted by modificationDate descending — newest first, suggesting it's
    /// the "original" to keep.
    var files: [DuplicateFile]

    /// Bytes reclaimable if we keep one file and delete the rest.
    var reclaimableBytes: UInt64 {
        sizeBytes * UInt64(max(files.count - 1, 0))
    }
}

/// One file inside a duplicate group.
struct DuplicateFile: Identifiable, Hashable {
    let id = UUID()
    let path: String
    let modificationDate: Date?
    /// User selection: true means "delete this copy".
    var markedForDeletion: Bool = false

    var name: String { (path as NSString).lastPathComponent }
    var directory: String { (path as NSString).deletingLastPathComponent }
}

/// User-tunable scan parameters.
struct DuplicateScanOptions {
    var roots: [URL] = DuplicateScanner.defaultRoots
    /// Skip files smaller than this — pointless to dedupe tiny files.
    var minSizeBytes: UInt64 = 1 * 1024 * 1024     // 1 MB
    /// Skip files inside .app bundles.
    var skipInsideAppBundles: Bool = true
    /// Skip dev caches.
    var skipDevCaches: Bool = true
}

// MARK: - Scanner

final class DuplicateScanner {

    static let shared = DuplicateScanner()
    private let fm = FileManager.default

    /// Same default roots as LargeFileScanner — interactive user folders.
    static var defaultRoots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appending(path: "Downloads"),
            home.appending(path: "Documents"),
            home.appending(path: "Desktop"),
            home.appending(path: "Movies"),
            home.appending(path: "Pictures")
        ]
    }

    private init() {}

    // MARK: - Public

    func scan(options: DuplicateScanOptions = .init()) async -> [DuplicateGroup] {
        await Task.detached(priority: .utility) { [options] in
            self.collect(options: options)
        }.value
    }

    // MARK: - Pipeline

    private func collect(options: DuplicateScanOptions) -> [DuplicateGroup] {
        // ── Stage 1: gather (path, size, modDate) for every regular file ──
        var bySize: [UInt64: [(URL, Date?)]] = [:]
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey,
                                       .isRegularFileKey]

        for root in options.roots {
            guard fm.fileExists(atPath: root.path),
                  !UserWhitelist.shared.isWhitelisted(root.path) else { continue }

            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else { continue }

            for case let url as URL in enumerator {
                if UserWhitelist.shared.isWhitelisted(url.path) {
                    enumerator.skipDescendants(); continue
                }
                if options.skipInsideAppBundles, isInsideAppBundle(url) {
                    enumerator.skipDescendants(); continue
                }
                if options.skipDevCaches, isInsideDevCache(url) {
                    enumerator.skipDescendants(); continue
                }

                guard let v = try? url.resourceValues(forKeys: Set(keys)),
                      v.isRegularFile == true,
                      let size = v.fileSize.map({ UInt64($0) }),
                      size >= options.minSizeBytes else { continue }

                bySize[size, default: []].append((url, v.contentModificationDate))
            }
        }

        // Only keep sizes with ≥ 2 files (others can't be duplicates)
        let candidates = bySize.filter { $0.value.count >= 2 }
        if candidates.isEmpty { return [] }

        // ── Stage 2: 4KB quick-hash bucketing ──
        var groupedByQuickHash: [String: [(URL, Date?)]] = [:]
        for (size, files) in candidates {
            var buckets: [String: [(URL, Date?)]] = [:]
            for entry in files {
                guard let hash = quickHash(entry.0) else { continue }
                let key = "\(size):\(hash)"
                buckets[key, default: []].append(entry)
            }
            // Stage 2 collisions become stage 3 candidates
            for (key, list) in buckets where list.count >= 2 {
                groupedByQuickHash[key] = list
            }
        }
        if groupedByQuickHash.isEmpty { return [] }

        // ── Stage 3: full SHA-256 verification ──
        var groups: [DuplicateGroup] = []
        for (_, candidatePool) in groupedByQuickHash {
            var byFullHash: [String: [(URL, Date?)]] = [:]
            for entry in candidatePool {
                autoreleasepool {
                    if let fullHash = streamingFullHash(entry.0) {
                        byFullHash[fullHash, default: []].append(entry)
                    }
                }
            }
            for (fullHash, list) in byFullHash where list.count >= 2 {
                guard let size = try? list[0].0.resourceValues(forKeys: [.fileSizeKey])
                    .fileSize.map({ UInt64($0) }) else { continue }
                let files = list
                    .sorted { ($0.1 ?? .distantPast) > ($1.1 ?? .distantPast) }
                    .map { DuplicateFile(path: $0.0.path, modificationDate: $0.1) }
                groups.append(DuplicateGroup(
                    contentHash: fullHash,
                    sizeBytes: size,
                    files: files
                ))
            }
        }

        // Largest savings first
        return groups.sorted { $0.reclaimableBytes > $1.reclaimableBytes }
    }

    // MARK: - Hashing

    /// Hash the first 4 KB of a file. Returns nil on read error.
    private func quickHash(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let chunk = handle.readData(ofLength: 4096)
        guard !chunk.isEmpty else { return nil }
        let digest = SHA256.hash(data: chunk)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    /// Hash an entire file by streaming 1 MB chunks. Uses autoreleasepool
    /// inside the read loop to keep peak memory bounded.
    private func streamingFullHash(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        let chunkSize = 1024 * 1024
        while true {
            var done = false
            autoreleasepool {
                let chunk = handle.readData(ofLength: chunkSize)
                if chunk.isEmpty { done = true; return }
                hasher.update(data: chunk)
            }
            if done { break }
        }
        let digest = hasher.finalize()
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Helpers

    private func isInsideAppBundle(_ url: URL) -> Bool {
        url.pathComponents.contains(where: { $0.hasSuffix(".app") })
    }
    private func isInsideDevCache(_ url: URL) -> Bool {
        let lower = url.path.lowercased()
        return lower.contains("/library/developer/xcode/deriveddata")
            || lower.contains("/library/developer/coresimulator")
            || lower.contains("/.gradle/")
            || lower.contains("/.npm/")
            || lower.contains("/library/caches/cocoapods")
    }
}
