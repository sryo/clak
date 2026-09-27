import XCTest
import CoreBluetooth
@testable import Clak

/// Pins the published GATT database. A bonded host caches the handles this
/// order produces, so reordering a service or characteristic silently breaks
/// every existing pairing.
final class GATTLayoutTests: XCTestCase {

    private typealias GATT = BLEHIDPeripheralManager.GATT

    private func macServices() -> [(String, CBMutableService)] {
        BLEHIDPeripheralManager.makeServiceList(reportMap: HIDReportMap(includeHorizontalScroll: false),
                                                publishesGenericAttributeService: true).services
    }

    private func service(_ uuid: CBUUID, in services: [(String, CBMutableService)]) throws -> CBMutableService {
        try XCTUnwrap(services.map(\.1).first { $0.uuid == uuid })
    }

    private func characteristics(of service: CBMutableService) -> [CBMutableCharacteristic] {
        (service.characteristics ?? []).compactMap { $0 as? CBMutableCharacteristic }
    }

    func testServiceOrder() {
        let services = macServices()
        XCTAssertEqual(services.map(\.0), ["_warmup", "GATT", "HID", "DeviceInfo"])
        XCTAssertEqual(services.map(\.1.uuid), [
            BLEHIDPeripheralManager.warmupServiceUUID,
            CBUUID(string: "00001801-0000-1000-8000-00805F9B34FB"),
            CBUUID(string: "00001812-0000-1000-8000-00805F9B34FB"),
            CBUUID(string: "0000180A-0000-1000-8000-00805F9B34FB"),
        ])
        XCTAssertFalse(services[0].1.isPrimary, "warm-up is secondary")
        XCTAssertTrue(services.dropFirst().allSatisfy { $0.1.isPrimary })
    }

    func testServiceUUIDsUseTheLongForm() {
        // CBUUID compares short and long forms equal; the add() check doesn't
        for (_, service) in macServices() {
            XCTAssertEqual(service.uuid.data.count, 16, service.uuid.uuidString)
        }
    }

    func testGenericAttributeService() throws {
        let gatt = try service(GATT.genericAttributeService, in: macServices())
        let chars = characteristics(of: gatt)
        XCTAssertEqual(chars.map(\.uuid), [GATT.serviceChanged])
        XCTAssertEqual(chars[0].properties, .indicate)
        XCTAssertEqual(chars[0].permissions, .readable)
    }

    func testHIDCharacteristicOrderPropertiesAndPermissions() throws {
        let hid = try service(GATT.hidService, in: macServices())
        let chars = characteristics(of: hid)
        XCTAssertEqual(chars.map(\.uuid), [
            GATT.hidInformation, GATT.reportMap, GATT.protocolMode,
            GATT.report, GATT.report, GATT.report, GATT.report,
            GATT.hidControlPoint,
        ])
        XCTAssertEqual(chars.map(\.properties.rawValue), [
            CBCharacteristicProperties.read.rawValue,
            CBCharacteristicProperties.read.rawValue,
            CBCharacteristicProperties([.read, .writeWithoutResponse]).rawValue,
            CBCharacteristicProperties([.read, .notify]).rawValue,
            CBCharacteristicProperties([.read, .notify]).rawValue,
            CBCharacteristicProperties([.read, .notify]).rawValue,
            CBCharacteristicProperties([.read, .write, .writeWithoutResponse]).rawValue,
            CBCharacteristicProperties.writeWithoutResponse.rawValue,
        ])
        XCTAssertEqual(chars.map(\.permissions.rawValue), [
            CBAttributePermissions.readable.rawValue,
            CBAttributePermissions.readEncryptionRequired.rawValue,
            CBAttributePermissions([.readable, .writeable]).rawValue,
            CBAttributePermissions.readEncryptionRequired.rawValue,
            CBAttributePermissions.readEncryptionRequired.rawValue,
            CBAttributePermissions.readEncryptionRequired.rawValue,
            CBAttributePermissions([.readEncryptionRequired, .writeEncryptionRequired]).rawValue,
            CBAttributePermissions.writeEncryptionRequired.rawValue,
        ])
    }

    func testReportReferenceDescriptors() throws {
        let hid = try service(GATT.hidService, in: macServices())
        let reports = characteristics(of: hid).filter { $0.uuid == GATT.report }
        let references: [Data?] = reports.map { report in
            (report.descriptors ?? []).first { $0.uuid == CBUUID(string: "2908") }?.value as? Data
        }
        XCTAssertEqual(references, [
            Data([0x01, 0x01]), // keyboard input
            Data([0x02, 0x01]), // consumer input
            Data([0x03, 0x01]), // mouse input
            Data([0x01, 0x02]), // LED output
        ])
    }

    func testStaticValues() throws {
        let services = macServices()
        let hid = characteristics(of: try service(GATT.hidService, in: services))
        XCTAssertEqual(hid[0].value, Data([0x11, 0x01, 0x00, 0x02]))
        XCTAssertEqual(hid[1].value, Data(HIDReportMap(includeHorizontalScroll: false).descriptor))
        XCTAssertTrue(hid.dropFirst(2).allSatisfy { $0.value == nil }, "dynamic characteristics")

        let info = characteristics(of: try service(GATT.deviceInfoService, in: services))
        XCTAssertEqual(info.map { $0.uuid }, [GATT.manufacturerName, GATT.modelNumber, GATT.pnpID])
        XCTAssertEqual(info[0].value, Data("Clak".utf8))
        XCTAssertEqual(info[1].value, Data("Virtual Keyboard".utf8))
        XCTAssertEqual(info[2].value, Data([0x02, 0xFF, 0xFF, 0x00, 0x01, 0x00, 0x01]))
    }

    func testBatteryServiceGoesLast() throws {
        let list = BLEHIDPeripheralManager.makeServiceList(
            reportMap: HIDReportMap(includeHorizontalScroll: false),
            publishesGenericAttributeService: true, publishesBatteryService: true)
        XCTAssertEqual(list.services.map(\.0), ["_warmup", "GATT", "HID", "DeviceInfo", "Battery"])
        let battery = list.services[4].1
        XCTAssertEqual(battery.uuid, CBUUID(string: "0000180F-0000-1000-8000-00805F9B34FB"))
        XCTAssertEqual(battery.uuid.data.count, 16)
        XCTAssertTrue(battery.isPrimary)
        let level = try XCTUnwrap(list.parts.batteryLevel)
        XCTAssertEqual(characteristics(of: battery).map { $0.uuid }, [GATT.batteryLevel])
        XCTAssertEqual(level.properties, [.read, .notify])
        XCTAssertEqual(level.permissions, .readEncryptionRequired)
        XCTAssertNil(level.value, "a notifying characteristic can't cache a value")
    }

    func testWithoutGenericAttributeService() {
        let services = BLEHIDPeripheralManager.makeServiceList(
            reportMap: HIDReportMap(includeHorizontalScroll: false), publishesGenericAttributeService: false)
        XCTAssertEqual(services.services.map(\.0), ["_warmup", "HID", "DeviceInfo"])
        XCTAssertNil(services.parts.serviceChanged)
    }
}
