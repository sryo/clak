import XCTest
@testable import ClakRemote

final class BringUpTests: XCTestCase {

    private func steps(_ status: RemoteController.Status, bluetoothOn: Bool, published: Bool) -> Int {
        BringUp.stepsDone(status: status, bluetoothOn: bluetoothOn, servicesPublished: published)
    }

    func testColdLaunchFillsInOrder() {
        XCTAssertEqual(steps(.waitingForBluetooth, bluetoothOn: false, published: false), 0)
        XCTAssertEqual(steps(.waitingForBluetooth, bluetoothOn: true, published: false), 1)
        XCTAssertEqual(steps(.waitingForBluetooth, bluetoothOn: true, published: true), 2)
        XCTAssertEqual(steps(.advertising, bluetoothOn: true, published: true), 3)
        XCTAssertEqual(steps(.connected, bluetoothOn: true, published: true), BringUp.stepCount)
    }

    func testRepublishDipsWhileTheKeyboardIsDown() {
        XCTAssertEqual(steps(.advertising, bluetoothOn: true, published: false), 1)
    }

    func testRadioLossEmptiesTheRing() {
        XCTAssertEqual(steps(.error("Bluetooth is powered off"), bluetoothOn: false, published: false), 0)
    }
}
