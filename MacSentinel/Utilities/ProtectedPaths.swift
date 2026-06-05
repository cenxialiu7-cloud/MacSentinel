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

    /// Why the caller wants to delete something.
    ///
    /// `.aiSafe` (default) — an AI assistant, MCP client, or batch operation
    ///   triggered this. Block deletion inside user content roots
    ///   (~/Documents, ~/Desktop, ~/Downloads, ~/Pictures, ~/Movies, ~/Music,
    ///   ~/Public) so a hallucinated path can't nuke the user's files.
    ///
    /// `.userExplicit` — a human clicked an item in the GUI (LargeFileView,
    ///   DuplicateFileView, etc.) where they can SEE each path before
    ///   pressing the trash button. Allow deletions inside user content
    ///   roots, but still hard-block keychain / mail / Safari / iCloud /
    ///   Photos library / system paths / explicit protectedFiles.
    enum DeletionPolicy {
        case aiSafe
        case userExplicit
    }

    /// User content roots — the bag-of-files folders that human users
    /// routinely fill with downloads, screenshots, exports, archives.
    /// Always exact-match-protected (you can't delete the root itself);
    /// tree-protected only under `.aiSafe`.
    static let userContentRoots: Set<String> = [
        "\(home)/Documents",
        "\(home)/Desktop",
        "\(home)/Downloads",
        "\(home)/Pictures",
        "\(home)/Music",
        "\(home)/Movies",
        "\(home)/Public",
    ]

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
    ///
    /// Under `policy = .userExplicit`, step 3 is relaxed for the user
    /// content roots (Documents/Desktop/Downloads/Pictures/Music/Movies/
    /// Public) — the user can see exactly what's queued, so we trust them.
    /// All other tree-protected paths (Keychain, Mail, Safari, iCloud,
    /// Photos library, system roots) remain blocked.
    static func isProtected(_ url: URL,
                            policy: DeletionPolicy = .aiSafe) -> Bool {
        let path = url.standardizedFileURL.path

        // Step 1 & 2: exact-match files / directories.
        // Exact match ALWAYS wins — even with policy = .userExplicit you can't
        // delete the root of ~/Downloads or ~/Pictures (that would nuke
        // hundreds of files in one click).
        if protected.contains(path) { return true }
        if protectedFiles.contains(path) { return true }

        // Step 3: inside a protected directory.
        // These roots are EXACT-MATCH only (their tree is fair game).
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
            // Under .userExplicit, user content roots are exact-only too.
            if policy == .userExplicit, userContentRoots.contains(protectedPath) {
                continue
            }
            if path.hasPrefix(protectedPath + "/") {
                return true
            }
        }
        return false
    }

    /// Validate that all URLs in a deletion batch are safe to delete.
    static func validate(_ urls: [URL],
                         policy: DeletionPolicy = .aiSafe) -> (safe: [URL], blocked: [URL]) {
        var safe: [URL] = []
        var blocked: [URL] = []
        for url in urls {
            if isProtected(url, policy: policy) {
                blocked.append(url)
            } else {
                safe.append(url)
            }
        }
        return (safe, blocked)
    }
}
