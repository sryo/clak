import Foundation
import os

enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? Constants.bundleIdentifier

    static let bluetooth = Logger(subsystem: subsystem, category: "Bluetooth")
    static let keyboard = Logger(subsystem: subsystem, category: "Keyboard")
    static let hid = Logger(subsystem: subsystem, category: "HID")
    static let app = Logger(subsystem: subsystem, category: "App")
    static let scripting = Logger(subsystem: subsystem, category: "Scripting")
}
