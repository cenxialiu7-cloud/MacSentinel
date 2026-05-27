//
//  LargeFileScanner.swift
//  MacSentinel
//
//  Walks user-facing folders (Downloads / Documents / Desktop / Movies …)
//  and surfaces files that match BOTH a minimum-size threshold AND a
//  minimum-age (days since modification) threshold. Optimised for low
//  memory by using FileManager.enumerator with a non-fatal error handler.
//

import Foundation

/// One result item from the large/old-file scan.
struct LargeFileItem: Identifiable, Hashable {
    let id = UUID()
    let path: String
    let sizeBytes: UInt64
    let modificationDate: Date?
    var isSelected: Bool = false

    var name: String { (path as NSString).lastPathComponent }
    var directory: String { (path as NSString).deletingLastPathComponent }
    var displaySize: String { ByteFormatter.format(sizeBytes) }

    var daysSinceModified: Int {
        guard let mod = modificationDate else { return 0 }
        return Calendar.current.dateComponents([.day], from: mod, to: Date()).day ?? 0
    }

    /// Reuses the shared RecommendationEvaluator so the action chip / reason
    /// popover behaviour matches the cache list.
    var recommendation: ItemRecommendation {
        RecommendationEvaluator.evaluate(
            path: path,
            modificationDate: modificationDate,
            sizeBytes: sizeBytes
        )
    }
}

/// User-tunable scan parameters.
struct LargeFileScanOptions {
    /// Minimum file size in bytes for a file to qualify.
    var minSizeBytes: UInt64 = 100 * 1024 * 1024     // 100 MB default
    /// Minimum age in days since last modification.
    var minDays: Int = 30
    /// Folders to walk (will skip any that don't exist / lack permission).
    var roots: [URL] = LargeFileScanner.defaultRoots
    /// Skip files inside .app bundles (otherwise we'd flood with framework binaries).
    var skipInsideAppBundles: Bool = true
    /// Skip files inside well-known dev-tool caches (those have their own scanner).
    var skipDevCaches: Bool = true
}

final class LargeFileScanner {

    static let shared = LargeFileScanner()
    private let fm = FileManager.default

    /// Common interactive user folders. Adding new roots is a one-line change.
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

    /// Run the scan. Returns items sorted by size descending.
    func scan(options: LargeFileScanOptions = .init()) async -> [LargeFileItem] {
        await Task.detached(priority: .utility) { [options] in
            self.collect(options: options)
        }.value
    }

    // MARK: - Implementation

    private func collect(options: LargeFileScanOptions) -> [LargeFileItem] {
        var results: [LargeFileItem] = []
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -options.minDays, to: Date())
            ?? Date(timeIntervalSinceNow: -Double(options.minDays) * 86400)
        let resourceKeys: [URLResourceKey] = [
            .fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isDirectoryKey
        ]

        for root in options.roots {
            guard fm.fileExists(atPath: root.path) else { continue }
            // User whitelist also applies at root level
            if UserWhitelist.shared.isWhitelisted(root.path) { continue }

            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: resourceKeys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in true /* keep going on permission errors */ }
            ) else { continue }

            for case let url as URL in enumerator {
                // Skip whole subtrees the user whitelisted
                if UserWhitelist.shared.isWhitelisted(url.path) {
                    enumerator.skipDescendants()
                    continue
                }

                // Skip .app bundle interiors
                if options.skipInsideAppBundles, isInsideAppBundle(url) {
                    enumerator.skipDescendants()
                    continue
                }

                // Skip dev caches (they have their own view)
                if options.skipDevCaches, isInsideDevCache(url) {
                    enumerator.skipDescendants()
                    continue
                }

                guard let values = try? url.resourceValues(forKeys: Set(resourceKeys)),
                      values.isRegularFile == true,
                      let size = values.fileSize.map({ UInt64($0) }),
                      size >= options.minSizeBytes else { continue }

                let modDate = values.contentModificationDate
                if let modDate, modDate > cutoffDate { continue }   // too recent

                results.append(LargeFileItem(
                    path: url.path,
                    sizeBytes: size,
                    modificationDate: modDate
                ))
            }
        }

        return results.sorted { $0.sizeBytes > $1.sizeBytes }
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
