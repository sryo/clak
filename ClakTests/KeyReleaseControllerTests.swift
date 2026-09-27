import XCTest
import AppKit
@testable import Clak

final class KeyReleaseControllerTests: XCTestCase {

    private var workspace: NotificationCenter!
    private var distributed: NotificationCenter!
    private var pressedKeys: PressedKeyTracker!
    private var modifiers: ModifierKeyTracker!
    private var releases = 0
    private var wakes = 0
    private var controller: KeyReleaseController!

    override func setUp() {
        super.setUp()
        workspace = NotificationCenter()
        distributed = NotificationCenter()
        pressedKeys = PressedKeyTracker()
        modifiers = ModifierKeyTracker()
        releases = 0
        wakes = 0
        controller = KeyReleaseController(
            pressedKeys: pressedKeys,
            modifierTracker: modifiers,
            workspaceCenter: workspace,
            distributedCenter: distributed,
            sendRelease: { [unowned self] in self.releases += 1 }
        )
        controller.onWake = { [unowned self] in self.wakes += 1 }
    }

    private func holdKeys() {
        pressedKeys.keyDown(keyCode: 0x00, usage: 0x04)
        modifiers.update(with: .maskShift)
    }

    private func assertReleased(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(releases, 1, file: file, line: line)
        XCTAssertTrue(pressedKeys.usages.isEmpty, file: file, line: line)
        XCTAssertEqual(modifiers.currentModifiers, 0, file: file, line: line)
    }

    func testReleaseAllClearsTrackersAndSendsRelease() {
        holdKeys()
        controller.releaseAll(reason: "test")
        assertReleased()
    }

    func testDroppedEventsReleaseEverything() {
        holdKeys()
        controller.captureDidDropEvents()
        assertReleased()
    }

    func testWillSleepReleasesEverything() {
        holdKeys()
        workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        assertReleased()
    }

    func testScreensDidSleepReleasesEverything() {
        holdKeys()
        workspace.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        assertReleased()
    }

    func testSessionResignReleasesEverything() {
        holdKeys()
        workspace.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        assertReleased()
    }

    func testScreenLockReleasesEverything() {
        holdKeys()
        distributed.post(name: KeyReleaseController.screenLockedNotification, object: nil)
        assertReleased()
    }

    func testWakeReleasesEverythingThenNotifies() {
        holdKeys()
        var releasedBeforeWake = false
        controller.onWake = { [unowned self] in releasedBeforeWake = self.releases == 1 }
        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        assertReleased()
        XCTAssertTrue(releasedBeforeWake)
    }

    func testUnrelatedNotificationsDoNothing() {
        holdKeys()
        workspace.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        XCTAssertEqual(releases, 0)
        XCTAssertEqual(pressedKeys.usages, [0x04])
        XCTAssertEqual(wakes, 0)
    }

    func testStopsObservingWhenDeallocated() {
        controller = nil
        workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        XCTAssertEqual(releases, 0)
    }
}
