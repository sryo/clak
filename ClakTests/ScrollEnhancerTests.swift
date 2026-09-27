import XCTest
@testable import Clak

final class ScrollEnhancerTests: XCTestCase {

    private var now = Date(timeIntervalSince1970: 1_000)
    private var answers: [UInt64: [Bool]] = [:]
    private var calls: [UInt64] = []

    private func makeEnhancer() -> ScrollEnhancer {
        ScrollEnhancer(
            resolver: { [unowned self] id in
                self.calls.append(id)
                return self.answers[id]?.isEmpty == false ? self.answers[id]!.removeFirst() : false
            },
            clock: { [unowned self] in self.now }
        )
    }

    func testPositiveVerdictIsCached() {
        answers[7] = [true, false]
        let enhancer = makeEnhancer()
        XCTAssertTrue(enhancer.isClakRemote(senderID: 7))
        now += 3_600
        XCTAssertTrue(enhancer.isClakRemote(senderID: 7))
        XCTAssertEqual(calls, [7])
    }

    /// A sender ID looked up before the Remote's HID service finished
    /// registering reads as "not us"; that answer must not stick for good.
    func testNegativeVerdictExpires() {
        answers[9] = [false, true]
        let enhancer = makeEnhancer()
        XCTAssertFalse(enhancer.isClakRemote(senderID: 9))
        now += ScrollEnhancer.negativeVerdictLifetime / 2
        XCTAssertFalse(enhancer.isClakRemote(senderID: 9))
        XCTAssertEqual(calls.count, 1, "cached within its lifetime — no registry walk per tick")
        now += ScrollEnhancer.negativeVerdictLifetime
        XCTAssertTrue(enhancer.isClakRemote(senderID: 9))
        XCTAssertEqual(calls.count, 2)
    }

    func testVerdictsAreKeptPerSender() {
        answers[1] = [true]
        answers[2] = [false]
        let enhancer = makeEnhancer()
        XCTAssertTrue(enhancer.isClakRemote(senderID: 1))
        XCTAssertFalse(enhancer.isClakRemote(senderID: 2))
        XCTAssertTrue(enhancer.isClakRemote(senderID: 1))
        XCTAssertEqual(calls, [1, 2])
    }

    /// The tap thread reads and fills the cache while stop() on main clears it.
    func testVerdictCacheIsSafeAcrossThreads() {
        let resolverCalls = NSCountedSet()
        let lock = NSLock()
        let enhancer = ScrollEnhancer(resolver: { id in
            lock.lock(); resolverCalls.add(id); lock.unlock()
            return id % 2 == 0
        })
        DispatchQueue.concurrentPerform(iterations: 20_000) { i in
            let id = UInt64(i % 500)
            XCTAssertEqual(enhancer.isClakRemote(senderID: id), id % 2 == 0)
            if i % 1_000 == 0 {
                enhancer.clearVerdicts()
            }
        }
    }
}
