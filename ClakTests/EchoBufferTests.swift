import XCTest
@testable import Clak

final class EchoBufferTests: XCTestCase {

    func testAppendAndRemoveLast() {
        var buffer = EchoBuffer()
        buffer.append("ab")
        buffer.removeLast()
        XCTAssertEqual(buffer.text, "a")
        buffer.removeLast()
        buffer.removeLast()
        XCTAssertEqual(buffer.text, "")
    }

    func testTenThousandAppendsStayWithinTheCapAndKeepTheNewestText() {
        var buffer = EchoBuffer()
        for i in 0..<10_000 {
            buffer.append(String(i % 10))
            XCTAssertLessThanOrEqual(buffer.text.count, EchoBuffer.maxLength)
        }
        XCTAssertGreaterThanOrEqual(buffer.text.count, EchoBuffer.visibleLength)
        XCTAssertTrue(buffer.text.hasSuffix("0123456789"))
    }

    /// Trimming is by chunks, so most appends don't re-copy the string.
    func testTrimsOnlyOncePerChunk() {
        var buffer = EchoBuffer()
        var trims = 0
        for _ in 0..<(EchoBuffer.maxLength * 10) {
            let before = buffer.text.count
            buffer.append("x")
            if buffer.text.count < before { trims += 1 }
        }
        let chunk = EchoBuffer.maxLength - EchoBuffer.visibleLength
        XCTAssertLessThanOrEqual(trims, EchoBuffer.maxLength * 10 / chunk + 1)
    }

    func testCountStaysRightAcrossCombiningMarks() {
        var buffer = EchoBuffer()
        for _ in 0..<(EchoBuffer.maxLength * 3) {
            buffer.append("e")
            buffer.append("\u{301}")
        }
        XCTAssertLessThanOrEqual(buffer.text.count, EchoBuffer.maxLength)
        XCTAssertEqual(buffer.count, buffer.text.count)
    }
}
