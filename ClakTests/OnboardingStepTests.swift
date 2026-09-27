import XCTest
@testable import Clak

final class OnboardingStepTests: XCTestCase {

    private func step(_ configure: (inout HUDInput) -> Void) -> OnboardingStep {
        var input = HUDInput()
        configure(&input)
        return OnboardingStep.current(input)
    }

    func testAllClearAndConnectedIsReady() {
        XCTAssertEqual(step { $0.isConnected = true }, .ready)
    }

    func testNotConnectedWaitsForDevice() {
        XCTAssertEqual(step { _ in }, .pairFromDevice)
    }

    // Each row adds one more blocker than the row below it; the step shown
    // must be the highest-priority blocker present.
    func testGateOrder() {
        let cases: [(String, (inout HUDInput) -> Void, OnboardingStep)] = [
            ("unsupported beats everything", {
                $0.bluetooth = .unsupported; $0.needsInputMonitoring = true
                $0.isAwaitingPairingConfirmation = true
            }, .bluetoothUnsupported),
            ("unauthorized beats input monitoring", {
                $0.bluetooth = .unauthorized; $0.needsInputMonitoring = true
            }, .allowBluetooth),
            ("off beats input monitoring", {
                $0.bluetooth = .off; $0.needsInputMonitoring = true
            }, .turnOnBluetooth),
            ("pairing code beats input monitoring: the dialog times out", {
                $0.isAwaitingPairingConfirmation = true; $0.needsInputMonitoring = true
            }, .confirmPairingCode),
            ("input monitoring beats waiting", {
                $0.needsInputMonitoring = true
            }, .allowInputMonitoring),
            ("input monitoring blocks a connected device too", {
                $0.needsInputMonitoring = true; $0.isConnected = true
            }, .allowInputMonitoring),
            ("accessibility only matters once connected", {
                $0.needsAccessibility = true
            }, .pairFromDevice),
            ("accessibility when connected", {
                $0.needsAccessibility = true; $0.isConnected = true
            }, .allowAccessibility),
        ]

        for (name, configure, expected) in cases {
            XCTAssertEqual(step(configure), expected, name)
        }
    }

    func testStepsThatNeedSettingsPointAtThem() {
        XCTAssertEqual(OnboardingStep.allowBluetooth.settings, .bluetoothPrivacy)
        XCTAssertEqual(OnboardingStep.turnOnBluetooth.settings, .bluetooth)
        XCTAssertEqual(OnboardingStep.allowInputMonitoring.settings, .inputMonitoring)
        XCTAssertEqual(OnboardingStep.allowAccessibility.settings, .accessibility)
        XCTAssertNil(OnboardingStep.pairFromDevice.settings)
        XCTAssertNil(OnboardingStep.ready.settings)
    }

    func testAvailabilityFromAuthorization() {
        XCTAssertEqual(BluetoothAvailability(isAuthorized: false, isPoweredOn: true), .unauthorized)
        XCTAssertEqual(BluetoothAvailability(isAuthorized: true, isPoweredOn: false), .off)
        XCTAssertEqual(BluetoothAvailability(isAuthorized: true, isPoweredOn: true), .on)
    }
}
