import CoreGraphics
import XCTest
@testable import Clak

final class KeyTapRelayTests: XCTestCase {

    private var delivered: [() -> Void] = []
    private var routed: [(KeyEventInput, KeyRoute)] = []

    private static let global = KeyGateSnapshot(
        isAppActive: false, isGlobalForwarding: true, isForwarding: true,
        isConnected: true, isRecording: false, isConsumeCapable: true, shortcuts: []
    )

    private func makeRelay() -> KeyTapRelay {
        let relay = KeyTapRelay(deliver: { [unowned self] in self.delivered.append($0) })
        relay.onRoute = { [unowned self] event, route, _ in self.routed.append((event, route)) }
        return relay
    }

    private func runDelivered() {
        let blocks = delivered
        delivered.removeAll()
        blocks.forEach { $0() }
    }

    func testStartsClosed() {
        let relay = makeRelay()
        XCTAssertFalse(relay.route(.keyDown(keyCode: 0, modifiers: [], isAutorepeat: false)))
        runDelivered()
        XCTAssertEqual(routed.map(\.1), [.pass])
    }

    /// The tap's answer can't wait for main: it is decided from the
    /// published snapshot, and the work is handed off.
    func testConsumeIsDecidedWithoutRunningTheWork() {
        let relay = makeRelay()
        relay.publish(Self.global)
        XCTAssertTrue(relay.route(.keyDown(keyCode: 0, modifiers: [], isAutorepeat: false)))
        XCTAssertTrue(routed.isEmpty, "nothing runs until delivered")
        XCTAssertEqual(delivered.count, 1)
    }

    func testWorkIsDeliveredInEventOrderWithTheDecidedRoute() {
        let relay = makeRelay()
        relay.publish(Self.global)
        relay.route(.keyDown(keyCode: 0, modifiers: [], isAutorepeat: false))
        relay.route(.keyUp(keyCode: 0, modifiers: []))
        runDelivered()
        XCTAssertEqual(routed.map(\.0), [.keyDown(keyCode: 0, modifiers: [], isAutorepeat: false), .keyUp(keyCode: 0, modifiers: [])])
        XCTAssertEqual(routed.map(\.1), [
            KeyRoute(consume: true, action: .key(usage: 0x04)),
            KeyRoute(consume: true, action: .sendPressedKeys),
        ])
    }

    func testMainSeesTheSnapshotTheDecisionWasMadeWith() {
        let relay = makeRelay()
        var seen: KeyGateSnapshot?
        relay.onRoute = { _, _, snapshot in seen = snapshot }
        relay.publish(Self.global)
        relay.route(.keyUp(keyCode: 0, modifiers: []))
        var paused = Self.global
        paused.isForwarding = false
        relay.publish(paused)
        runDelivered()
        XCTAssertEqual(seen, Self.global)
    }

    func testPublishFromAnotherThreadIsSeen() {
        let relay = makeRelay()
        let published = expectation(description: "published")
        DispatchQueue.global().async {
            relay.publish(Self.global)
            published.fulfill()
        }
        wait(for: [published], timeout: 1)
        XCTAssertTrue(relay.route(.keyUp(keyCode: 0, modifiers: [])))
    }

    func testConcurrentPublishAndRouteDoNotTear() {
        let relay = KeyTapRelay(deliver: { _ in })
        var open = Self.global
        open.shortcuts = (0..<20).map { ShortcutBinding(keyCode: UInt16($0), modifiers: 0, action: .pasteToDevice) }
        DispatchQueue.concurrentPerform(iterations: 2_000) { i in
            if i % 2 == 0 {
                relay.publish(i % 4 == 0 ? open : Self.global)
            } else {
                _ = relay.route(.keyDown(keyCode: 30, modifiers: [], isAutorepeat: false))
            }
        }
    }
}
