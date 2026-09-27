import XCTest
import CoreBluetooth
@testable import Clak

final class HOGPWriteValidationTests: XCTestCase {

    private typealias Manager = BLEHIDPeripheralManager

    func testControlPointCommands() {
        XCTAssertEqual(try Manager.parseControlPoint(Data([0x00]), offset: 0).get(), .suspend)
        XCTAssertEqual(try Manager.parseControlPoint(Data([0x01]), offset: 0).get(), .exitSuspend)
    }

    func testControlPointRejectsUnknownValues() {
        XCTAssertEqual(error(Manager.parseControlPoint(Data([0x02]), offset: 0)), .requestNotSupported)
    }

    func testControlPointRejectsWrongLengthAndOffset() {
        XCTAssertEqual(error(Manager.parseControlPoint(Data(), offset: 0)), .invalidAttributeValueLength)
        XCTAssertEqual(error(Manager.parseControlPoint(nil, offset: 0)), .invalidAttributeValueLength)
        XCTAssertEqual(error(Manager.parseControlPoint(Data([0x00, 0x00]), offset: 0)), .invalidAttributeValueLength)
        XCTAssertEqual(error(Manager.parseControlPoint(Data([0x00]), offset: 1)), .invalidOffset)
    }

    func testProtocolModeValues() {
        XCTAssertEqual(try Manager.validateProtocolMode(Data([0x00]), offset: 0).get(), 0x00)
        XCTAssertEqual(try Manager.validateProtocolMode(Data([0x01]), offset: 0).get(), 0x01)
        XCTAssertEqual(error(Manager.validateProtocolMode(Data([0x02]), offset: 0)), .requestNotSupported)
        XCTAssertEqual(error(Manager.validateProtocolMode(Data([0x01, 0x01]), offset: 0)), .invalidAttributeValueLength)
        XCTAssertEqual(error(Manager.validateProtocolMode(Data([0x01]), offset: 2)), .invalidOffset)
    }

    private func error<T>(_ result: Result<T, CBATTError>) -> CBATTError.Code? {
        if case .failure(let error) = result { return error.code }
        return nil
    }
}
