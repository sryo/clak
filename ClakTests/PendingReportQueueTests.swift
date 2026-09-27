import XCTest
@testable import Clak

final class PendingReportQueueTests: XCTestCase {

    private final class Target {}

    private let keyboard = Target()
    private let consumer = Target()
    private let mouse = Target()
    private var queue = PendingReportQueue<Target>(capacity: 8)

    override func setUp() {
        queue = PendingReportQueue<Target>(capacity: 8)
    }

    private func key(_ code: UInt8, modifiers: UInt8 = 0) -> Data {
        Data([modifiers, 0, code, 0, 0, 0, 0, 0])
    }

    private func move(_ dx: Int8, _ dy: Int8, buttons: UInt8 = 0, wheel: Int8 = 0, pan: Int8? = nil) -> Data {
        var bytes = [buttons, UInt8(bitPattern: dx), UInt8(bitPattern: dy), UInt8(bitPattern: wheel)]
        if let pan { bytes.append(UInt8(bitPattern: pan)) }
        return Data(bytes)
    }

    private var datas: [Data] { queue.entries.map(\.data) }

    // MARK: - Mouse coalescing

    func testMotionWithSameButtonsSums() {
        XCTAssertEqual(queue.enqueue(move(3, -2), on: mouse, kind: .mouse), .appended)
        XCTAssertEqual(queue.enqueue(move(4, -5, wheel: 1), on: mouse, kind: .mouse), .coalesced)
        XCTAssertEqual(datas, [move(7, -7, wheel: 1)])
    }

    func testPanSumsInTheFiveByteReport() {
        queue.enqueue(move(1, 1, pan: 2), on: mouse, kind: .mouse)
        queue.enqueue(move(1, 1, pan: -5), on: mouse, kind: .mouse)
        XCTAssertEqual(datas, [move(2, 2, pan: -3)])
    }

    func testOverflowSplitsIntoASecondReport() {
        queue.enqueue(move(100, -100), on: mouse, kind: .mouse)
        XCTAssertEqual(queue.enqueue(move(100, -100), on: mouse, kind: .mouse), .appended)
        XCTAssertEqual(datas, [move(127, -127), move(73, -73)])
    }

    func testMinus128ReadsAsMinus127() {
        queue.enqueue(move(-128, 0), on: mouse, kind: .mouse)
        queue.enqueue(move(-128, 0), on: mouse, kind: .mouse)
        XCTAssertEqual(datas, [move(-127, 0), move(-127, 0)])
    }

    func testButtonChangeNeverMerges() {
        queue.enqueue(move(5, 5), on: mouse, kind: .mouse)
        queue.enqueue(move(0, 0, buttons: 1), on: mouse, kind: .mouse)
        queue.enqueue(move(2, 2, buttons: 1), on: mouse, kind: .mouse)
        queue.enqueue(move(0, 0), on: mouse, kind: .mouse)
        XCTAssertEqual(datas, [move(5, 5), move(2, 2, buttons: 1), move(0, 0)])
    }

    func testNoMergeAcrossAnotherTarget() {
        // A modifier change between two moves must stay between them
        queue.enqueue(move(1, 0), on: mouse, kind: .mouse)
        queue.enqueue(key(0, modifiers: 0x08), on: keyboard, kind: .keyboard)
        queue.enqueue(move(1, 0), on: mouse, kind: .mouse)
        XCTAssertEqual(queue.count, 3)
    }

    func testNoMergeAcrossRecipients() {
        let a = UUID(), b = UUID()
        queue.enqueue(move(1, 0), on: mouse, kind: .mouse, recipient: a)
        queue.enqueue(move(1, 0), on: mouse, kind: .mouse, recipient: b)
        XCTAssertEqual(queue.count, 2)
    }

    // MARK: - Absolute pointer

    func testAbsolutePositionReplacesTheLastWithSameButtons() {
        let pointer = Target()
        queue.enqueue(Data([0, 1, 0, 1, 0, 0]), on: pointer, kind: .absolutePointer)
        XCTAssertEqual(queue.enqueue(Data([0, 9, 0, 9, 0, 0]), on: pointer, kind: .absolutePointer), .coalesced)
        queue.enqueue(Data([1, 9, 0, 9, 0, 0]), on: pointer, kind: .absolutePointer)
        XCTAssertEqual(datas, [Data([0, 9, 0, 9, 0, 0]), Data([1, 9, 0, 9, 0, 0])])
    }

    // MARK: - Duplicates

    func testIdenticalKeyboardReportIsDropped() {
        queue.enqueue(key(0x04), on: keyboard, kind: .keyboard)
        XCTAssertEqual(queue.enqueue(key(0x04), on: keyboard, kind: .keyboard), .coalesced)
        XCTAssertEqual(queue.count, 1)
    }

    func testPressReleasePressIsKept() {
        let play = Data([0xCD, 0x00]), release = Data([0x00, 0x00])
        queue.enqueue(play, on: consumer, kind: .consumer)
        queue.enqueue(release, on: consumer, kind: .consumer)
        queue.enqueue(play, on: consumer, kind: .consumer)
        XCTAssertEqual(datas, [play, release, play])
    }

    // MARK: - Full queue

    func testFullQueueKeepsTheFinalKeyUp() {
        for i in 0..<4 {
            queue.enqueue(key(0x04 + UInt8(i)), on: keyboard, kind: .keyboard)
            queue.enqueue(key(0), on: keyboard, kind: .keyboard)
        }
        XCTAssertEqual(queue.count, 8)
        let outcome = queue.enqueue(Data([0xE9, 0x00]), on: consumer, kind: .consumer)
        XCTAssertEqual(outcome, .collapsed(dropped: 7))
        XCTAssertEqual(datas, [key(0), Data([0xE9, 0x00])], "last key-up survives, order kept")
    }

    func testCollapseKeepsOneEntryPerTargetInOrder() {
        queue.enqueue(key(0x04), on: keyboard, kind: .keyboard)
        queue.enqueue(move(0, 0, buttons: 1), on: mouse, kind: .mouse)
        queue.enqueue(key(0), on: keyboard, kind: .keyboard)
        queue.enqueue(move(0, 0), on: mouse, kind: .mouse)
        queue.collapseToLatestState()
        XCTAssertEqual(datas, [key(0), move(0, 0)])
    }

    func testCountNeverExceedsCapacity() {
        for i in 0..<100 {
            queue.enqueue(key(UInt8(i % 50) + 4), on: keyboard, kind: .keyboard)
            queue.enqueue(move(0, 0, buttons: UInt8(i % 2)), on: mouse, kind: .mouse)
            XCTAssertLessThanOrEqual(queue.count, queue.capacity)
        }
    }

    // MARK: - FIFO

    func testFirstAndRemoveFirstAreFIFO() {
        queue.enqueue(key(0x04), on: keyboard, kind: .keyboard)
        queue.enqueue(key(0), on: keyboard, kind: .keyboard)
        XCTAssertEqual(queue.first?.data, key(0x04))
        queue.removeFirst()
        XCTAssertEqual(queue.first?.data, key(0))
    }

    func testRemoveAllForOneRecipientKeepsTheOthers() {
        let a = UUID(), b = UUID()
        queue.enqueue(key(0x04), on: keyboard, kind: .keyboard, recipient: a)
        queue.enqueue(key(0x05), on: keyboard, kind: .keyboard, recipient: b)
        queue.enqueue(key(0), on: keyboard, kind: .keyboard, recipient: a)
        queue.removeAll(recipient: a)
        XCTAssertEqual(datas, [key(0x05)])
    }
}
