import Foundation
import AppKit

// MARK: - TrashService
//
// macOS doesn't release disk space until the user's Trash is emptied.
// Provides:
//   • trashContents() — list what's in the Trash + total size
//   • emptyTrash()     — empty the Trash via NSWorkspace
//   • findInTrash(by:) — locate a previously-trashed item for undo

enum TrashService {

    /// User's .Trash directory.
    static var trashURL: URL {
        FileManager.default.urls(for: .trashDirectory, in: .userDomainMask)[0]
    }

    /// Total size of everything in the trash.
    /// Note: may fail if the calling process lacks FDA; returns 0 in that case.
    static func totalSize() -> UInt64 {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: trashURL,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isDirectoryKey]
        ) else { return 0 }

        return entries.reduce(0) { acc, url in
            acc + directorySize(url)
        }
    }

    /// Trigger NSWorkspace "Empty Trash" action — same as Finder's command.
    /// Returns true if the empty operation was initiated.
    static func emptyTrash() -> Bool {
        // AppKit doesn't expose a direct empty-trash API; use osascript
        // tell application "Finder" to empty trash, which has the right
        // ACL chain to work even when the calling process lacks FDA.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "tell application \"Finder\" to empty trash"]
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    // MARK: - Private

    private static func directorySize(_ url: URL) -> UInt64 {
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
