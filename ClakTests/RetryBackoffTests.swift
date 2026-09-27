import XCTest
@testable import Clak

final class RetryBackoffTests: XCTestCase {

    func testDelayDoublesFromEightToACeilingOf120() {
        let backoff = RetryBackoff()
        XCTAssertEqual((0...5).map(backoff.delay(afterAttempts:)), [8, 16, 32, 64, 120, 120])
    }

    func testNextDelayAdvancesAndResetStartsOver() {
        var backoff = RetryBackoff()
        XCTAssertEqual(backoff.nextDelay(), 8)
        XCTAssertEqual(backoff.nextDelay(), 16)
        XCTAssertEqual(backoff.attempts, 2)
        backoff.reset()
        XCTAssertEqual(backoff.attempts, 0)
        XCTAssertEqual(backoff.nextDelay(), 8)
    }

    func testCustomParameters() {
        let backoff = RetryBackoff(firstDelay: 1, maxDelay: 5)
        XCTAssertEqual((0...4).map(backoff.delay(afterAttempts:)), [1, 2, 4, 5, 5])
    }

    func testHugeAttemptCountStaysAtTheCeiling() {
        XCTAssertEqual(RetryBackoff().delay(afterAttempts: 10_000), 120)
    }
}
