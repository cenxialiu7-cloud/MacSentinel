import Foundation

/// Paths that MacSentinel will NEVER delete under any circumstances.
///
/// Design philosophy (post-redesign):
/// Instead of blanket-protecting `~/Library` and then trying to enumerate
/// every legitimate cleanup target as a "deletable sub-path" (which led to
/// LaunchAgents / Developer / Application Scripts being mistakenly blocked),
/// we now invert the model:
///
///   • A SHORT list of paths/files that are unambiguously sensitive and must
///     never be touched (Keychain, Mail, Messages, Safari history, banking
///     data, etc.).
///   • Anything else is allowed to be scanned/deleted at the *individual
///     file* level. Safety is handled by SafetyLevel + SafetyClassifier
///     rather than by directory-tree protection.
///
/// This eliminates the "ProtectedPaths blocks legitimate cleanup" bug class.
enum ProtectedPaths {

    static let home = FileManager.default.homeDirectoryForCurrentUser.path

    /// Paths that are unconditionally protected regardless of safety level.
    /// These are checked with prefix matching: if the target path is INSIDE
    /// one of these (or equals one), deletion is blocked.
    ///
    /// Kept deliberately small. Each entry must have a clear justification:
    /// deleting it would lose unrecoverable user data, break login, or
    /// expose security state.
    static let protected: Set<String> = [
        // ── Root-level system paths (BSD layer; rm -rf / would be catastrophic) ──
        "/",
        "/System",
        "/usr",
        "/bin",
        "/sbin",
        "/etc",
        "/private/etc",
        "/private/var/db",
        "/Library/Apple",
        "/Library/CoreMediaIO",

        // ── User home itself + user content roots ──
        // (We allow deleting INSIDE these, but never the directory itself.)
        home,
        "\(home)/Documents",
        "\(home)/Desktop",
        "\(home)/Downloads",
        "\(home)/Pictures",
        "\(home)/Music",
        "\(home)/Movies",
        "\(home)/Public",

        // ── Cleanup roots (cleaning INSIDE is allowed; the root itself
        //    must never be passed as a single deletion target — that would
        //    nuke every app's cache in one shot) ──
        "\(home)/Library/Caches",
        "\(home)/Library/Logs",
        "\(home)/Library/Application Support",
        "\(home)/Library/Containers",
        "\(home)/Library/Group Containers",

        // ── Identity / Security state ──
        "\(home)/Library/Keychains",                  // Login keychain, item passwords
        "\(home)/Library/Cookies",                     // Authentication cookies
        "\(home)/Library/Sharing",                     // Sharing prefs / sync state

        // ── Personal communications history ──
        "\(home)/Library/Mail",                        // Mail.app data + drafts
        "\(home)/Library/Messages",                    // iMessage history
        "\(home)/Library/IMServices",
        "\(home)/Library/FaceTime",
        "\(home)/Library/Voicemail",

        // ── Browser bookmarks / history (NOT caches — those are fair game) ──
        "\(home)/Library/Safari",                      // Bookmarks, history, reading list

        // ── iCloud sync engines ──
        "\(home)/Library/iCloud",
        "\(home)/Library/Mobile Documents",            // iCloud Drive

        // ── Calendar / Contacts / Notes ──
        "\(home)/Library/Calendars",
        "\(home)/Library/AddressBook",
        "\(home)/Library/Notes",
        "\(home)/Library/Reminders",

        // ── Photos library (the database; NOT its caches) ──
        "\(home)/Pictures/Photos Library.photoslibrary",

        // ── Financial / health (if present) ──
        "\(home)/Library/Application Support/Finance",
        "\(home)/Library/Health",
    ]

    /// Sensitive files INSIDE otherwise-cleanable directories.
    /// We use a single SQLite database or plist that we never want to lose
    /// even if its parent directory contains many clearable caches.
    static let protectedFiles: Set<String> = [
        "\(home)/Library/Safari/History.db",
        "\(home)/Library/Safari/Bookmarks.plist",
        "\(home)/Library/Application Support/com.apple.TCC/TCC.db",
        "\(home)/Library/Application Support/CrashReporter/SubmitDiagInfo.domains",
    ]

    /// Returns true if the given URL is protected and must not be deleted.
    /// Algorithm:
    ///   1. Exact match against `protected` set            → protected
    ///   2. Exact match against `protectedFiles` set       → protected
    ///   3. Path is INSIDE a protected directory           → protected
    ///   4. Otherwise                                       → allowed
    static func isProtected(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path

        // Step 1 & 2: exact-match files / directories
        if protected.contains(path) { return true }
        if protectedFiles.contains(path) { return true }

        // Step 3: inside a protected directory.
        // Important nuance: `home` (~) itself is exact-match only — we DO want
        // to allow MacSentinel to clean ~/Library/Caches, ~/.npm/_cacache, etc.
        // But user content roots (Documents, Desktop, Downloads, Pictures…)
        // and sensitive Library subdirs (Keychains, Mail, Safari…) remain
        // tree-protected.
        let exactMatchOnly: Set<String> = [
            home,   // ← only the home dir itself, not its subtree
            // Cleanup roots — protect the *root*, allow cleaning INSIDE.
            "\(home)/Library/Caches",
            "\(home)/Library/Logs",
            "\(home)/Library/Application Support",
            "\(home)/Library/Containers",
            "\(home)/Library/Group Containers",
        ]

        for protectedPath in protected {
            if exactMatchOnly.contains(protectedPath) { continue }
            if path.hasPrefix(protectedPath + "/") {
                return true
            }
        }
        return false
    }

    /// Validate that all URLs in a deletion batch are safe to delete.
    static func validate(_ urls: [URL]) -> (safe: [URL], blocked: [URL]) {
        var safe: [URL] = []
        var blocked: [URL] = []
        for url in urls {
            if isProtected(url) {
                blocked.append(url)
            } else {
                safe.append(url)
            }
        }
        return (safe, blocked)
    }
}
