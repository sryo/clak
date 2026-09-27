import XCTest
import IOKit.ps
@testable import Clak

final class MacBatteryMonitorTests: XCTestCase {

    private func battery(_ current: Int, of max: Int, present: Bool = true,
                         type: String = kIOPSInternalBatteryType) -> [String: Any] {
        [kIOPSTypeKey: type, kIOPSIsPresentKey: present,
         kIOPSCurrentCapacityKey: current, kIOPSMaxCapacityKey: max]
    }

    func testPercentOfTheInternalBattery() {
        XCTAssertEqual(MacBatteryMonitor.level(from: [battery(50, of: 100)]), 50)
        XCTAssertEqual(MacBatteryMonitor.level(from: [battery(2, of: 3)]), 67)
    }

    func testClampsToOneHundred() {
        XCTAssertEqual(MacBatteryMonitor.level(from: [battery(120, of: 100)]), 100)
    }

    func testDesktopsReportFull() {
        XCTAssertEqual(MacBatteryMonitor.level(from: []), 100)
        XCTAssertEqual(MacBatteryMonitor.level(from: [battery(10, of: 100, type: "UPS")]), 100)
        XCTAssertEqual(MacBatteryMonitor.level(from: [battery(10, of: 0)]), 100)
    }

    func testIgnoresABatteryThatIsNotPresent() {
        XCTAssertEqual(MacBatteryMonitor.level(from: [battery(10, of: 100, present: false),
                                                      battery(80, of: 100)]), 80)
    }
}
