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

    // MARK: - Deterministic ordering

    func testPrimaryIsMostRecentlyConnected() {
        let manager = DeviceConnectionManager()
        for id in ["A", "B", "C", "D", "E", "F", "G", "H"] {
            manager.addConnectedDevice(ConnectedDevice(id: id, name: id))
            XCTAssertEqual(manager.primaryDevice?.id, id)
        }
        XCTAssertEqual(manager.allDevices.map(\.id), ["H", "G", "F", "E", "D", "C", "B", "A"])
    }

    func testRemovingPrimaryFallsBackToPreviousConnection() {
        let manager = DeviceConnectionManager()
        manager.addConnectedDevice(ConnectedDevice(id: "A", name: "a"))
        manager.addConnectedDevice(ConnectedDevice(id: "B", name: "b"))
        manager.addConnectedDevice(ConnectedDevice(id: "C", name: "c"))
        manager.removeDevice(id: "C")
        XCTAssertEqual(manager.primaryDevice?.id, "B")
        manager.removeDevice(id: "A")
        XCTAssertEqual(manager.primaryDevice?.id, "B")
    }

    func testReconnectingMovesDeviceToFront() {
        let manager = DeviceConnectionManager()
        manager.addConnectedDevice(ConnectedDevice(id: "A", name: "a"))
        manager.addConnectedDevice(ConnectedDevice(id: "B", name: "b"))
        manager.addConnectedDevice(ConnectedDevice(id: "A", name: "a2"))
        XCTAssertEqual(manager.allDevices.map(\.id), ["A", "B"])
        XCTAssertEqual(manager.primaryDevice?.name, "a2")
    }
}
