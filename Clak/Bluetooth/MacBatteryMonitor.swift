#if os(macOS)
import Foundation
import IOKit.ps

/// The Mac's internal battery as the keyboard's Battery Level. Desktops (and
/// Macs on a UPS only) report 100, so a host never warns about a keyboard
/// that can't run down.
final class MacBatteryMonitor: BatteryLevelSource {

    private(set) var level: UInt8
    var onChange: ((UInt8) -> Void)?

    private var runLoopSource: CFRunLoopSource?

    init() {
        level = Self.currentLevel()
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<MacBatteryMonitor>.fromOpaque(context).takeUnretainedValue().refresh()
        }, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        runLoopSource = source
    }

    deinit {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
    }

    private func refresh() {
        let newLevel = Self.currentLevel()
        guard newLevel != level else { return }
        level = newLevel
        onChange?(newLevel)
    }

    private static func currentLevel() -> UInt8 {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return 100
        }
        let descriptions = list.compactMap {
            IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any]
        }
        return level(from: descriptions)
    }

    /// Percent of the first present internal battery; 100 when there is none.
    static func level(from descriptions: [[String: Any]]) -> UInt8 {
        guard let battery = descriptions.first(where: {
            $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
                && ($0[kIOPSIsPresentKey] as? Bool ?? true)
        }),
              let current = battery[kIOPSCurrentCapacityKey] as? Int,
              let max = battery[kIOPSMaxCapacityKey] as? Int, max > 0 else {
            return 100
        }
        let percent = (Double(current) * 100 / Double(max)).rounded()
        return UInt8(Swift.max(0, Swift.min(100, percent)))
    }
}
#endif
