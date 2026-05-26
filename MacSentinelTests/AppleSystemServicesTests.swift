import XCTest
@testable import MacSentinel

final class AppleSystemServicesTests: XCTestCase {

    // MARK: - Known daemons hit detection

    func testKnownAppleDaemonsAreRecognized() {
        // These are real bundle IDs we saw misclassified during the cleanup session.
        let trueAppleServices = [
            "com.apple.geod",
            "com.apple.mediaanalysisd",
            "com.apple.photoanalysisd",
            "com.apple.photolibraryd",
            "com.apple.routined",
            "com.apple.AvatarUI.AvatarPickerMemojiPicker",
            "com.apple.ScreenSaver.Engine.legacyScreenSaver",
            "com.apple.AMPArtworkAgent",
            "com.apple.voicebankingd",
            "com.apple.wallpaper.agent",
            "com.apple.helpd",
            "com.apple.parsecd",
            "com.apple.CloudDocs.iCloudDriveFileProvider",
        ]
        for id in trueAppleServices {
            XCTAssertTrue(AppleSystemServices.isAppleSystemService(id),
                          "Should recognize \(id) as Apple system service")
        }
    }

    // MARK: - Apple group container prefix matching

    func testAppleGroupContainerPrefixes() {
        XCTAssertTrue(AppleSystemServices.isAppleSystemService("74J34U3R6X.com.apple.iWork"))
        XCTAssertTrue(AppleSystemServices.isAppleSystemService("243LU875E5.groups.com.apple.podcasts"))
    }

    // MARK: - Shortcuts workflow groups

    func testWorkflowGroupsAreRecognized() {
        XCTAssertTrue(AppleSystemServices.isAppleSystemService("group.is.workflow.my.app"))
        XCTAssertTrue(AppleSystemServices.isAppleSystemService("group.is.workflow.shortcuts"))
    }

    // MARK: - Negative cases (NOT Apple system services)

    func testThirdPartyAppsAreNotMisclassified() {
        let thirdParty = [
            "com.tencent.xinWeChat",
            "jp.naver.line.mac",
            "UBF8T346G9.Office",       // Microsoft Office team
            "com.google.Chrome",
            "VUTU7AKEUR.jp.naver.line.mac",
            "com.adobe.accmac.ACCFinderSync",
            "com.lemon.lvpro",
        ]
        for id in thirdParty {
            XCTAssertFalse(AppleSystemServices.isAppleSystemService(id),
                           "Should NOT classify \(id) as Apple system service")
        }
    }

    // MARK: - com.apple.* prefix fallback

    func testUnknownComAppleStillClassified() {
        // Even if we haven't seen the specific bundle ID, anything starting
        // with com.apple. is treated as system service.
        XCTAssertTrue(AppleSystemServices.isAppleSystemService("com.apple.somenewservice"))
    }

    // MARK: - Human descriptions

    func testHumanDescriptionsAvailable() {
        XCTAssertNotNil(AppleSystemServices.humanDescription(for: "com.apple.mediaanalysisd"))
        XCTAssertNotNil(AppleSystemServices.humanDescription(for: "com.apple.geod"))
        // Generic com.apple.* falls back to a generic description
        XCTAssertNotNil(AppleSystemServices.humanDescription(for: "com.apple.somenewthing"))
        // Third-party returns nil
        XCTAssertNil(AppleSystemServices.humanDescription(for: "com.example.app"))
    }
}
