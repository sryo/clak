import XCTest
@testable import Clak

/// Pins the HID report descriptor byte-for-byte. These bytes were captured
/// from the shipped implementation BEFORE the descriptor was extracted into
/// HIDReportMap: any diff here means every bonded device must re-pair.
/// Do not "fix" a failure by updating the constants unless a report-map
/// change (and the forced re-pair) is intentional.
final class HIDReportMapTests: XCTestCase {

    /// Clak (macOS): 4-byte mouse report, no AC Pan.
    private static let pinnedDescriptorHex =
        "05010906A1018501050719E029E71500250175019508810295017508810105071900"
        + "29E7150026E70075089506810005081901290515002501750195059102750395019101C0"
        + "050C0901A1018502150026FF0319002AFF03751095018100C0"
        + "05010902A10185030901A1000509190129031500250195037501810295017505810105"
        + "01093009311581257F75089502810609381581257F750895018106"
        + "C0C0"

    /// ClakRemote (iOS): AC Pan block spliced in before the collection ends.
    private static let pinnedDescriptorWithPanHex =
        "05010906A1018501050719E029E71500250175019508810295017508810105071900"
        + "29E7150026E70075089506810005081901290515002501750195059102750395019101C0"
        + "050C0901A1018502150026FF0319002AFF03751095018100C0"
        + "05010902A10185030901A1000509190129031500250195037501810295017505810105"
        + "01093009311581257F75089502810609381581257F750895018106"
        + "050C0A38021581257F750895018106"
        + "C0C0"

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined()
    }

    func testMacDescriptorMatchesPinnedBytes() {
        let map = HIDReportMap(includeHorizontalScroll: false)
        XCTAssertEqual(map.descriptor.count, 159)
        XCTAssertEqual(hex(map.descriptor), Self.pinnedDescriptorHex)
    }

    func testRemoteDescriptorMatchesPinnedBytes() {
        let map = HIDReportMap(includeHorizontalScroll: true)
        XCTAssertEqual(map.descriptor.count, 174)
        XCTAssertEqual(hex(map.descriptor), Self.pinnedDescriptorWithPanHex)
    }

    func testPanVariantOnlyAppendsBeforeCollectionEnd() {
        let base = HIDReportMap(includeHorizontalScroll: false).descriptor
        let pan = HIDReportMap(includeHorizontalScroll: true).descriptor
        // Identical prefix up to the shared end; the pan block sits between
        // the wheel input and the two End Collection bytes
        XCTAssertEqual(Array(base.dropLast(2)), Array(pan.prefix(base.count - 2)))
        XCTAssertEqual(Array(base.suffix(2)), [0xC0, 0xC0])
        XCTAssertEqual(Array(pan.suffix(2)), [0xC0, 0xC0])
    }

    func testReportSizesMatchDescriptor() {
        XCTAssertEqual(HIDReportMap.keyboardReportSize, 8)
        XCTAssertEqual(HIDReportMap.consumerReportSize, 2)
        XCTAssertEqual(HIDReportMap(includeHorizontalScroll: false).mouseReportSize, 4)
        XCTAssertEqual(HIDReportMap(includeHorizontalScroll: true).mouseReportSize, 5)
    }
}
