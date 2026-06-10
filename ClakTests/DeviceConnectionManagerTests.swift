import XCTest
@testable import Clak

final class DeviceConnectionManagerTests: XCTestCase {

    func testAddAndRemoveDevice() {
        let manager = DeviceConnectionManager()
        let device = ConnectedDevice(id: "AAA", name: "iPhone")

        manager.addConnectedDevice(device)
        XCTAssertEqual(manager.allDevices, [device])
        XCTAssertEqual(manager.primaryDevice, device)

        manager.removeDevice(id: "AAA")
        XCTAssertTrue(manager.allDevices.isEmpty)
        XCTAssertNil(manager.primaryDevice)
    }

    func testRemoveUnknownDeviceIsNoop() {
        let manager = DeviceConnectionManager()
        manager.addConnectedDevice(ConnectedDevice(id: "A", name: "a"))
        manager.removeDevice(id: "B")
        XCTAssertEqual(manager.allDevices.count, 1)
    }

    func testAddingSameIDReplaces() {
        let manager = DeviceConnectionManager()
        manager.addConnectedDevice(ConnectedDevice(id: "A", name: "first"))
        manager.addConnectedDevice(ConnectedDevice(id: "A", name: "second"))
        XCTAssertEqual(manager.allDevices.count, 1)
        XCTAssertEqual(manager.primaryDevice?.name, "second")
    }

    func testRemoveAllDevices() {
        let manager = DeviceConnectionManager()
        manager.addConnectedDevice(ConnectedDevice(id: "A", name: "a"))
        manager.addConnectedDevice(ConnectedDevice(id: "B", name: "b"))
        manager.removeAllDevices()
        XCTAssertTrue(manager.allDevices.isEmpty)
    }
}
