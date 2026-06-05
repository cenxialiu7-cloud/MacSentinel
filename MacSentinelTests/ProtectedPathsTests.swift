import XCTest
@testable import MacSentinel

final class ProtectedPathsTests: XCTestCase {

    private var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    // MARK: - System roots

    func testSystemRootsAreProtected() {
        XCTAssertTrue(ProtectedPaths.isProtected(URL(fileURLWithPath: "/")))
        XCTAssertTrue(ProtectedPaths.isProtected(URL(fileURLWithPath: "/System")))
        XCTAssertTrue(ProtectedPaths.isProtected(URL(fileURLWithPath: "/usr")))
        XCTAssertTrue(ProtectedPaths.isProtected(URL(fileURLWithPath: "/bin")))
        XCTAssertTrue(ProtectedPaths.isProtected(URL(fileURLWithPath: "/System/Library/Frameworks")))
    }

    // MARK: - User content roots (tree-protected)

    func testUserContentRootsAreProtected() {
        XCTAssertTrue(ProtectedPaths.isProtected(home.appendingPathComponent("Documents")))
        XCTAssertTrue(ProtectedPaths.isProtected(home.appendingPathComponent("Desktop")))
        XCTAssertTrue(ProtectedPaths.isProtected(home.appendingPathComponent("Downloads")))
        XCTAssertTrue(ProtectedPaths.isProtected(home.appendingPathComponent("Pictures")))
        XCTAssertTrue(ProtectedPaths.isProtected(home.appendingPathComponent("Music")))
        XCTAssertTrue(ProtectedPaths.isProtected(home.appendingPathComponent("Movies")))
    }

    func testFilesInsideUserContentRootsAreProtected() {
        // Files INSIDE user content roots are still protected — AI shouldn't be
        // able to delete the user's personal files even if they target them.
        XCTAssertTrue(ProtectedPaths.isProtected(home.appendingPathComponent("Documents/Tax Return 2024.pdf")))
        XCTAssertTrue(ProtectedPaths.isProtected(home.appendingPathComponent("Downloads/important.zip")))
        XCTAssertTrue(ProtectedPaths.isProtected(home.appendingPathComponent("Desktop/screenshot.png")))
    }

    // MARK: - Cleanup roots — root protected, INSIDE allowed
    //
    // Regression for the v1.1.0 bug where scanBrowserCaches() fell back to
    // ~/Library/Caches itself when a vendor's cache dir was missing.

    func testLibraryCachesRootCannotBeDeletedWholesale() {
        XCTAssertTrue(ProtectedPaths.isProtected(home.appendingPathComponent("Library/Caches")))
        XCTAssertTrue(ProtectedPaths.isProtected(home.appendingPathComponent("Library/Logs")))
        XCTAssertTrue(ProtectedPaths.isProtected(home.appendingPathComponent("Library/Application Support")))
        XCTAssertTrue(ProtectedPaths.isProtected(home.appendingPathComponent("Library/Containers")))
        XCTAssertTrue(ProtectedPaths.isProtected(home.appendingPathComponent("Library/Group Containers")))
    }

    // MARK: - DeletionPolicy — large/duplicate file delete bug regression

    func testUserContentRootsTreeProtectedUnderAISafe() {
        // .aiSafe is the default behaviour — MCP / batch callers can't
        // touch anything inside Downloads/Documents/Desktop/Movies/Pictures.
        let fake = home.appendingPathComponent("Downloads/old-installer.dmg")
        XCTAssertTrue(ProtectedPaths.isProtected(fake))
        XCTAssertTrue(ProtectedPaths.isProtected(fake, policy: .aiSafe))
        XCTAssertTrue(ProtectedPaths.isProtected(home.appendingPathComponent("Pictures/Screenshot.png"), policy: .aiSafe))
        XCTAssertTrue(ProtectedPaths.isProtected(home.appendingPathComponent("Documents/old.zip"), policy: .aiSafe))
    }

    func testUserContentRootsCleanableUnderUserExplicit() {
        // .userExplicit — the user picked the file in the GUI. Allow it.
        // (This is what fixes the "delete then file reappears" bug in
        // LargeFileView / DuplicateFileView.)
        XCTAssertFalse(ProtectedPaths.isProtected(home.appendingPathComponent("Downloads/old-installer.dmg"), policy: .userExplicit))
        XCTAssertFalse(ProtectedPaths.isProtected(home.appendingPathComponent("Pictures/old-screenshot.png"), policy: .userExplicit))
        XCTAssertFalse(ProtectedPaths.isProtected(home.appendingPathComponent("Desktop/scratch.zip"), policy: .userExplicit))
        XCTAssertFalse(ProtectedPaths.isProtected(home.appendingPathComponent("Movies/old.mov"), policy: .userExplicit))
    }

    func testUserContentRootsThemselvesStillProtectedEvenWithUserExplicit() {
        // Even with .userExplicit we never delete the root itself —
        // that would nuke the whole folder.
        XCTAssertTrue(ProtectedPaths.isProtected(home.appendingPathComponent("Downloads"), policy: .userExplicit))
        XCTAssertTrue(ProtectedPaths.isProtected(home.appendingPathComponent("Pictures"), policy: .userExplicit))
    }

    func testPhotosLibraryAlwaysProtectedEvenWithUserExplicit() {
        // The Photos Library SQLite database lives INSIDE ~/Pictures but
        // is its own protected entry — the user could click "delete" by
        // mistake and lose every photo.
        let inside = home.appendingPathComponent("Pictures/Photos Library.photoslibrary/database/Photos.sqlite")
        XCTAssertTrue(ProtectedPaths.isProtected(inside, policy: .userExplicit))
        XCTAssertTrue(ProtectedPaths.isProtected(inside, policy: .aiSafe))
    }

    func testKeychainAlwaysProtectedEvenWithUserExplicit() {
        let kc = home.appendingPathComponent("Library/Keychains/login.keychain-db")
        XCTAssertTrue(ProtectedPaths.isProtected(kc, policy: .userExplicit))
        XCTAssertTrue(ProtectedPaths.isProtected(kc, policy: .aiSafe))
    }

    func testInsideLibraryCachesStillCleanable() {
        // The whole point of MacSentinel — we MUST still be able to clean
        // individual vendors and per-profile cache subdirs.
        XCTAssertFalse(ProtectedPaths.isProtected(home.appendingPathComponent("Library/Caches/Google")))
        XCTAssertFalse(ProtectedPaths.isProtected(home.appendingPathComponent("Library/Caches/Google/Chrome/Profile 5")))
        XCTAssertFalse(ProtectedPaths.isProtected(home.appendingPathComponent("Library/Caches/Homebrew")))
        XCTAssertFalse(ProtectedPaths.isProtected(home.appendingPathComponent("Library/Logs/DiagnosticReports")))
        XCTAssertFalse(ProtectedPaths.isProtected(home.appendingPathComponent("Library/Application Support/MacSentinel")))
    }

    // MARK: - Sensitive Library subdirs

    func testSensitiveLibrarySubdirsAreProtected() {
        XCTAssertTrue(ProtectedPaths.isProtected(home.appendingPathComponent("Library/Keychains")))
        XCTAssertTrue(ProtectedPaths.isProtected(home.appendingPathComponent("Library/Keychains/login.keychain-db")))
        XCTAssertTrue(ProtectedPaths.isProtected(home.appendingPathComponent("Library/Mail")))
        XCTAssertTrue(ProtectedPaths.isProtected(home.appendingPathComponent("Library/Messages")))
        XCTAssertTrue(ProtectedPaths.isProtected(home.appendingPathComponent("Library/Safari")))
        XCTAssertTrue(ProtectedPaths.isProtected(home.appendingPathComponent("Library/Cookies")))
        XCTAssertTrue(ProtectedPaths.isProtected(home.appendingPathComponent("Library/iCloud")))
        XCTAssertTrue(ProtectedPaths.isProtected(home.appendingPathComponent("Library/Mobile Documents")))
    }

    // MARK: - Library subdirs that SHOULD be cleanable (the actual bug we fixed)

    func testLibraryCachesIsCleanable() {
        XCTAssertFalse(ProtectedPaths.isProtected(home.appendingPathComponent("Library/Caches/com.example.test")))
    }

    func testLibraryLogsIsCleanable() {
        XCTAssertFalse(ProtectedPaths.isProtected(home.appendingPathComponent("Library/Logs/SomeApp")))
    }

    func testLibraryDeveloperIsCleanable() {
        // Xcode DerivedData — the bug we hit live, must be allowed.
        XCTAssertFalse(ProtectedPaths.isProtected(home.appendingPathComponent("Library/Developer/Xcode/DerivedData")))
        XCTAssertFalse(ProtectedPaths.isProtected(home.appendingPathComponent("Library/Developer/Xcode/iOS DeviceSupport/15.0")))
    }

    func testLibraryLaunchAgentsIsCleanable() {
        // Orphan LaunchAgents — the original bug.
        XCTAssertFalse(ProtectedPaths.isProtected(home.appendingPathComponent("Library/LaunchAgents/com.bad.minergate.plist")))
    }

    func testLibraryContainersIsCleanable() {
        XCTAssertFalse(ProtectedPaths.isProtected(home.appendingPathComponent("Library/Containers/com.removed.app")))
    }

    func testLibraryApplicationSupportIsCleanable() {
        XCTAssertFalse(ProtectedPaths.isProtected(home.appendingPathComponent("Library/Application Support/SomeRemovedApp")))
    }

    func testLibraryPreferencesIsCleanable() {
        XCTAssertFalse(ProtectedPaths.isProtected(home.appendingPathComponent("Library/Preferences/com.example.app.plist")))
    }

    // MARK: - Sensitive files inside otherwise-cleanable dirs

    func testSafariHistoryFileIsProtectedEvenInsideLibrary() {
        // Library/Safari is tree-protected, but call out the most critical
        // file explicitly via protectedFiles too.
        let history = home.appendingPathComponent("Library/Safari/History.db")
        XCTAssertTrue(ProtectedPaths.isProtected(history))
    }

    // MARK: - validate() batch

    func testValidateBatch() {
        let safe1   = home.appendingPathComponent("Library/Caches/test")
        let safe2   = home.appendingPathComponent("Library/Logs/old.log")
        let block1  = home.appendingPathComponent("Downloads/important.zip")
        let block2  = home.appendingPathComponent("Library/Keychains/login.keychain-db")
        let (safeURLs, blockedURLs) = ProtectedPaths.validate([safe1, safe2, block1, block2])
        XCTAssertEqual(safeURLs.count, 2)
        XCTAssertEqual(blockedURLs.count, 2)
    }
}
