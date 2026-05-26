import XCTest
@testable import MacSentinel

final class ByteFormatterTests: XCTestCase {

    func testFormatBytes() {
        XCTAssertTrue(ByteFormatter.format(0).contains("0"))
        XCTAssertTrue(ByteFormatter.format(1024).contains("KB") || ByteFormatter.format(1024).contains("1"))
        XCTAssertTrue(ByteFormatter.format(1_048_576).contains("MB"))
        XCTAssertTrue(ByteFormatter.format(1_073_741_824).contains("GB"))
    }

    func testFormatSpeed() {
        XCTAssertTrue(ByteFormatter.formatSpeed(500).contains("B/s"))
        XCTAssertTrue(ByteFormatter.formatSpeed(1_500_000).contains("MB/s"))
        XCTAssertTrue(ByteFormatter.formatSpeed(2_000_000_000).contains("GB/s"))
    }

    func testFormatTemp() {
        XCTAssertEqual(ByteFormatter.formatTemp(-1), "—")
        XCTAssertTrue(ByteFormatter.formatTemp(72.0).contains("°C"))
    }
}
