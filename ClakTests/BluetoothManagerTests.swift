import XCTest
@testable import Clak

final class BluetoothManagerTests: XCTestCase {

    private var link: FakeHIDPeripheralLink!
    private var clock: ManualScheduler!
    private var resolved: [String] = []
    private var manager: BluetoothManager!

    private let phoneA = HIDCentral(id: UUID(), name: "Phone A")
    private let phoneB = HIDCentral(id: UUID(), name: "Phone B")

    override func setUp() {
        super.setUp()
        link = FakeHIDPeripheralLink()
        clock = ManualScheduler()
        resolved = []
        manager = BluetoothManager(
            link: link,
            scheduler: clock.scheduler,
            keystrokeResolver: { [unowned self] text in
                self.resolved.append(text)
                return KeyboardLayoutMapper.keystrokes(for: text) { KeyCodeTranslator.hidKeycode(for: $0) }
            }
        )
    }

    private var isConnected: Bool {
        if case .connected = manager.connectionState { return true }
        return false
    }

    // MARK: - Connection authority (ghost "connected")

    func testConnectShowsDevice() {
        link.connect(phoneA)
        XCTAssertEqual(manager.connectionState, .connected(ConnectedDevice(id: phoneA.id.uuidString, name: "Phone A")))
        XCTAssertEqual(manager.connectedDevices.map(\.name), ["Phone A"])
    }

    /// bluetoothd restarting drops every link without an unsubscribe; once
    /// advertising resumes the manager must stop claiming a connection.
    func testRadioResetThenAdvertisingIsNotConnected() {
        link.connect(phoneA)
        link.isConnected = false
        link.hasCentral = false
        manager.peripheralDidPowerOn()
        manager.peripheralDidStartAdvertising()
        XCTAssertEqual(manager.connectionState, .advertising)
        XCTAssertTrue(manager.connectedDevices.isEmpty)
    }

    func testAdvertisingWhileStillConnectedKeepsConnection() {
        link.connect(phoneA)
        manager.peripheralDidStartAdvertising()
        XCTAssertTrue(isConnected)
    }

    func testPowerOffClearsDevicesAndCapsLock() {
        link.connect(phoneA)
        manager.peripheralDidReceiveLEDState(0x02)
        link.isConnected = false
        manager.peripheralDidFail(.poweredOff)
        XCTAssertTrue(manager.connectedDevices.isEmpty)
        XCTAssertFalse(manager.capsLockActive)
    }

    func testStaleDeviceDoesNotSurviveLastDisconnect() {
        link.connect(phoneA)
        link.isConnected = false
        manager.peripheralDidFail(.poweredOff)
        manager.peripheralDidPowerOn()
        link.connect(phoneB)
        let advertiseBefore = link.startAdvertisingCalls
        link.disconnect(phoneB)
        XCTAssertEqual(manager.connectionState, .advertising)
        XCTAssertTrue(manager.connectedDevices.isEmpty)
        XCTAssertGreaterThan(link.startAdvertisingCalls, advertiseBefore)
    }

    func testDisconnectOfOneOfTwoKeepsTheOther() {
        link.connect(phoneA)
        link.connect(phoneB)
        link.disconnect(phoneB, othersRemain: true)
        XCTAssertEqual(manager.connectionState, .connected(ConnectedDevice(id: phoneA.id.uuidString, name: "Phone A")))
    }

    func testDisconnectWhileLinkIsGoneClearsEveryDevice() {
        link.connect(phoneA)
        link.connect(phoneB)
        // A dropped while B was the one reporting — the link is the authority
        link.disconnect(phoneB, othersRemain: false)
        XCTAssertEqual(manager.connectionState, .advertising)
        XCTAssertTrue(manager.connectedDevices.isEmpty)
    }

    // MARK: - Caps Lock

    func testCapsLockResetsWhenLastDeviceDisconnects() {
        var reported: [Bool] = []
        manager.onLEDStateChange = { reported.append($0) }
        link.connect(phoneA)
        manager.peripheralDidReceiveLEDState(0x02)
        link.disconnect(phoneA)
        XCTAssertFalse(manager.capsLockActive)
        XCTAssertEqual(reported, [true, false])
    }

    // MARK: - Retry

    func testRetryableFailureRetriesWithBackoff() {
        manager.peripheralDidFail(.advertisingFailed("x"))
        XCTAssertEqual(manager.connectionState, .error(BLEHIDPeripheralManager.Failure.advertisingFailed("x").message))
        XCTAssertEqual(clock.pendingDelays, [8])
        clock.advance(by: 8)
        XCTAssertEqual(link.startAdvertisingCalls, 1)

        manager.peripheralDidFail(.advertisingFailed("x"))
        XCTAssertEqual(clock.pendingDelays, [16])
    }

    func testRepeatedFailuresDoNotStackRetries() {
        manager.peripheralDidFail(.serviceSetupFailed("a"))
        manager.peripheralDidFail(.serviceSetupFailed("b"))
        manager.peripheralDidFail(.serviceSetupFailed("c"))
        XCTAssertEqual(clock.pendingDelays.count, 1)
        clock.advance(by: 1_000)
        XCTAssertEqual(link.startAdvertisingCalls, 1)
    }

    func testNonRetryableFailureDoesNotRetry() {
        manager.peripheralDidFail(.unauthorized)
        clock.advance(by: 1_000)
        XCTAssertEqual(link.startAdvertisingCalls, 0)
    }

    func testConnectCancelsRetryAndResetsBackoff() {
        manager.peripheralDidFail(.advertisingFailed("x"))
        clock.advance(by: 8)
        manager.peripheralDidFail(.advertisingFailed("x"))
        link.connect(phoneA)
        XCTAssertTrue(clock.pendingDelays.isEmpty)
        link.disconnect(phoneA)
        manager.peripheralDidFail(.advertisingFailed("x"))
        XCTAssertEqual(clock.pendingDelays, [8])
    }

    func testAdvertisingFailureWithLiveLinkStaysConnected() {
        link.connect(phoneA)
        manager.peripheralDidFail(.advertisingFailed("x"))
        XCTAssertTrue(isConnected)
        XCTAssertTrue(clock.pendingDelays.isEmpty)
    }

    // MARK: - Reconnect (menu)

    func testReconnectWithNoCentralRepublishes() {
        manager.disconnectAndReAdvertise()
        XCTAssertEqual(link.republishCalls, 1)
        XCTAssertEqual(link.stopAdvertisingCalls, 0)
    }

    func testReconnectWithCentralCyclesAdvertisingOnce() {
        link.connect(phoneA)
        let before = link.startAdvertisingCalls
        manager.disconnectAndReAdvertise()
        manager.disconnectAndReAdvertise()
        XCTAssertEqual(link.republishCalls, 0, "republishing would pull the database out from under the host")
        clock.advance(by: 5)
        XCTAssertEqual(link.startAdvertisingCalls - before, 1)
    }

    // MARK: - Wake

    func testWakeWithoutConnectionAdvertises() {
        manager.handleWake()
        XCTAssertEqual(link.startAdvertisingCalls, 1)
    }

    /// After sleep the link may only look alive: advertise for a while so a
    /// host whose connection really dropped can find us again.
    func testWakeWhileClaimingConnectionAdvertisesForABoundedWindow() {
        link.connect(phoneA)
        manager.handleWake()
        XCTAssertEqual(link.startAdvertisingCalls, 1)
        clock.advance(by: BluetoothManager.wakeAdvertisingWindow)
        XCTAssertEqual(link.stopAdvertisingCalls, 1)
    }

    func testFreshSubscribeDuringWakeWindowEndsIt() {
        link.connect(phoneA)
        manager.handleWake()
        link.connect(phoneB)
        clock.advance(by: BluetoothManager.wakeAdvertisingWindow)
        XCTAssertEqual(link.stopAdvertisingCalls, 0)
    }

    func testWakeWindowLeavesAdvertisingOnIfTheLinkDied() {
        link.connect(phoneA)
        manager.handleWake()
        link.isConnected = false
        clock.advance(by: BluetoothManager.wakeAdvertisingWindow)
        XCTAssertEqual(link.stopAdvertisingCalls, 0)
    }

    // MARK: - Paste

    func testTextIsResolvedOnTheCallingMainThreadBeforeQueueing() {
        link.connect(phoneA)
        manager.sendText("ab")
        XCTAssertEqual(resolved, ["ab"], "resolved synchronously, before the paced send starts")

        let sent = expectation(description: "paste delivered")
        DispatchQueue.global().async {
            while true {
                let count = DispatchQueue.main.sync { self.link.keyboardReports.count }
                if count >= 4 { break }
                Thread.sleep(forTimeInterval: 0.005)
            }
            sent.fulfill()
        }
        wait(for: [sent], timeout: 5)
        XCTAssertEqual(link.keyboardReports.map(\.keyCodes), [[0x04], [], [0x05], []])
    }

    // MARK: - Bluetooth availability

    func testAvailabilityFollowsFailures() {
        typealias M = BluetoothManager
        XCTAssertEqual(M.availability(for: .error("x"), failure: .poweredOff), .off)
        XCTAssertEqual(M.availability(for: .error("x"), failure: .unauthorized), .unauthorized)
        XCTAssertEqual(M.availability(for: .error("x"), failure: .unsupported), .unsupported)
        XCTAssertEqual(M.availability(for: .advertising, failure: .poweredOff), .on)
        XCTAssertEqual(M.availability(for: .connected(ConnectedDevice(id: "a", name: "a")), failure: nil), .on)
    }

    func testTransientFailuresAndLaunchStateLeaveAvailabilityAlone() {
        XCTAssertNil(BluetoothManager.availability(for: .error("x"), failure: .advertisingFailed("x")))
        XCTAssertNil(BluetoothManager.availability(for: .poweredOff, failure: nil),
                     "the launch state isn't a radio report — mapping it flashes 'Bluetooth is off'")
    }

    func testLastFailureIsExposedAndClearedByAdvertising() {
        manager.peripheralDidFail(.poweredOff)
        XCTAssertEqual(manager.lastFailure, .poweredOff)
        manager.peripheralDidStartAdvertising()
        XCTAssertNil(manager.lastFailure)
    }

    // MARK: - Pairing confirmation

    func testPendingCentralAwaitsPairingUntilItSubscribes() {
        var changes: [Bool] = []
        manager.onPairingStateChange = { changes.append($0) }
        link.seePending(phoneA)
        XCTAssertFalse(manager.isAwaitingPairingConfirmation, "a bonded host subscribes within the grace")
        clock.advance(by: BluetoothManager.pairingPromptGrace)
        XCTAssertTrue(manager.isAwaitingPairingConfirmation)
        link.connect(phoneA)
        XCTAssertFalse(manager.isAwaitingPairingConfirmation)
        XCTAssertEqual(changes, [true, false])
    }

    func testBondedReconnectNeverShowsPairing() {
        var changes: [Bool] = []
        manager.onPairingStateChange = { changes.append($0) }
        link.seePending(phoneA)
        clock.advance(by: 1)
        link.connect(phoneA)
        clock.advance(by: 60)
        XCTAssertEqual(changes, [])
    }

    func testPairingWaitEndsOnDisconnect() {
        link.seePending(phoneA)
        clock.advance(by: BluetoothManager.pairingPromptGrace)
        link.disconnect(phoneA)
        XCTAssertFalse(manager.isAwaitingPairingConfirmation)
    }

    func testPairingWaitTimesOut() {
        link.seePending(phoneA)
        clock.advance(by: BluetoothManager.pairingPromptGrace)
        clock.advance(by: BluetoothManager.pairingConfirmationTimeout - 1)
        XCTAssertTrue(manager.isAwaitingPairingConfirmation)
        clock.advance(by: 1)
        XCTAssertFalse(manager.isAwaitingPairingConfirmation)
    }

    func testPairingWaitEndsOnRadioLoss() {
        link.seePending(phoneA)
        clock.advance(by: BluetoothManager.pairingPromptGrace)
        manager.peripheralDidFail(.poweredOff)
        XCTAssertFalse(manager.isAwaitingPairingConfirmation)
    }
}
