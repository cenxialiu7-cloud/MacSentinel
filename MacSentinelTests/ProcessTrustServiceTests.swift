import XCTest
@testable import MacSentinel

final class ProcessTrustServiceTests: XCTestCase {

    /// Regression test for the misclassification observed live on user's system:
    /// `XProtectPluginService` at /Library/Apple/System/... was tagged L2 (ad-hoc)
    /// instead of L5 (Apple system) because /Library/Apple/ wasn't in the
    /// isAppleSystemPath whitelist.
    ///
    /// Note: This is an integration test — it evaluates real binaries on the
    /// running system. It's marked skip if the expected binaries aren't present.
    func testXProtectPluginServiceClassifiesAsAppleSystem() throws {
        let path = "/Library/Apple/System/Library/CoreServices/XProtect.app/Contents/XPCServices/XProtectPluginService.xpc/Contents/MacOS/XProtectPluginService"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("XProtectPluginService not present (running on non-macOS-14 system?)")
        }
        let info = ProcessTrustService.shared.evaluate(pid: 0, path: path, name: "XProtectPluginService")
        XCTAssertEqual(info.trustLevel, .l5_appleSystem,
                        "XProtect is an Apple system service and must classify as L5")
    }

    func testRemotePairingdClassifiesAsAppleSystem() throws {
        let path = "/Library/Apple/System/Library/PrivateFrameworks/RemotePairing.framework/Versions/A/XPCServices/remotepairingd.xpc/Contents/MacOS/remotepairingd"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("remotepairingd not present")
        }
        let info = ProcessTrustService.shared.evaluate(pid: 0, path: path, name: "remotepairingd")
        XCTAssertEqual(info.trustLevel, .l5_appleSystem,
                        "remotepairingd is an Apple system service and must classify as L5")
    }

    /// Sanity: the new fallback "Apple authority + Apple Root in chain" recognizes
    /// well-known Apple binaries from canonical paths too.
    func testLaunchctlClassifiesAsAppleSystem() throws {
        let path = "/bin/launchctl"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("launchctl not present")
        }
        let info = ProcessTrustService.shared.evaluate(pid: 1, path: path, name: "launchctl")
        XCTAssertEqual(info.trustLevel, .l5_appleSystem)
    }
}
