import XCTest
@testable import Clak

final class EventTapThreadTests: XCTestCase {

    func testRunsBlocksOnItsOwnRunLoopOffMain() {
        let tapThread = EventTapThread(name: "test.taps")
        let (isMain, loop) = tapThread.performAndWait { (Thread.isMainThread, CFRunLoopGetCurrent()) }
        XCTAssertFalse(isMain)
        XCTAssertTrue(loop === tapThread.runLoop)
        XCTAssertFalse(tapThread.runLoop === CFRunLoopGetMain())
    }

    func testRunsAtUserInteractivePriority() {
        let tapThread = EventTapThread(name: "test.taps")
        XCTAssertEqual(tapThread.performAndWait { Thread.current.qualityOfService }, .userInteractive)
    }

    /// The taps must keep being serviced while the main thread is busy.
    func testKeepsRunningWhileMainIsBlocked() {
        let tapThread = EventTapThread(name: "test.taps")
        let ran = DispatchSemaphore(value: 0)
        tapThread.perform { ran.signal() }
        // Blocks main without spinning its run loop: only the tap thread can signal
        XCTAssertEqual(ran.wait(timeout: .now() + 1), .success)
    }

    func testPerformAndWaitFromTheTapThreadDoesNotDeadlock() {
        let tapThread = EventTapThread(name: "test.taps")
        let value = tapThread.performAndWait { tapThread.performAndWait { 42 } }
        XCTAssertEqual(value, 42)
    }

    /// The run loop releases a performed block only after it returns, so a
    /// waiter can wake while the tap thread still holds the closure.
    func testPerformAndWaitSurvivesRepeatedHandoffs() {
        let tapThread = EventTapThread(name: "test.taps")
        var sum = 0
        for i in 0..<20_000 {
            sum += tapThread.performAndWait { i & 1 }
        }
        XCTAssertEqual(sum, 10_000)
    }
}
