import Foundation

/// Pure value describing the HID report map and the payload sizes it implies.
///
/// The descriptor bytes and the reports sent over BLE must agree byte-for-byte;
/// keeping both in one value type (frozen at init) makes that invariant
/// testable and impossible to desynchronize after services are published.
///
/// CRITICAL: the emitted bytes are pinned by HIDReportMapTests. Any change to
/// them invalidates existing bonds — every paired device must
/// "Forget This Device" and re-pair.
struct HIDReportMap: Equatable {
    /// Adds AC Pan (horizontal scroll) to the mouse report, making it 5 bytes.
    /// ClakRemote (iOS) opts in; Clak (macOS) keeps the original 4-byte report
    /// so existing bonds stay valid.
    let includeHorizontalScroll: Bool

    static let keyboardReportSize = 8
    static let consumerReportSize = 2

    var mouseReportSize: Int {
        includeHorizontalScroll ? 5 : 4
    }

    /// Combo HID report descriptor: keyboard (ID 1), consumer control (ID 2),
    /// mouse (ID 3). Notification payloads exclude the report ID — the
    /// per-characteristic Report Reference descriptor maps each characteristic
    /// to its ID.
    var descriptor: [UInt8] {
        Self.baseDescriptor
            + (includeHorizontalScroll ? Self.acPanBlock : [])
            + Self.descriptorEnd
    }

    private static let baseDescriptor: [UInt8] = [
        // ---- Keyboard (Report ID 1) ----
        0x05, 0x01,       // Usage Page (Generic Desktop)
        0x09, 0x06,       // Usage (Keyboard)
        0xA1, 0x01,       // Collection (Application)
        0x85, 0x01,       //   Report ID (1)
        // Modifier keys (8 bits)
        0x05, 0x07,       //   Usage Page (Keyboard/Keypad)
        0x19, 0xE0,       //   Usage Minimum (Left Control)
        0x29, 0xE7,       //   Usage Maximum (Right GUI)
        0x15, 0x00,       //   Logical Minimum (0)
        0x25, 0x01,       //   Logical Maximum (1)
        0x75, 0x01,       //   Report Size (1)
        0x95, 0x08,       //   Report Count (8)
        0x81, 0x02,       //   Input (Data, Variable, Absolute)
        // Reserved byte
        0x95, 0x01,       //   Report Count (1)
        0x75, 0x08,       //   Report Size (8)
        0x81, 0x01,       //   Input (Constant)
        // Key codes (6 bytes)
        0x05, 0x07,       //   Usage Page (Keyboard/Keypad)
        0x19, 0x00,       //   Usage Minimum (0)
        0x29, 0xE7,       //   Usage Maximum (231)
        0x15, 0x00,       //   Logical Minimum (0)
        0x26, 0xE7, 0x00, //   Logical Maximum (231)
        0x75, 0x08,       //   Report Size (8)
        0x95, 0x06,       //   Report Count (6)
        0x81, 0x00,       //   Input (Data, Array)
        // LED Output Report (5 LEDs + 3 padding bits = 1 byte)
        0x05, 0x08,       //   Usage Page (LEDs)
        0x19, 0x01,       //   Usage Minimum (Num Lock)
        0x29, 0x05,       //   Usage Maximum (Kana)
        0x15, 0x00,       //   Logical Minimum (0)
        0x25, 0x01,       //   Logical Maximum (1)
        0x75, 0x01,       //   Report Size (1)
        0x95, 0x05,       //   Report Count (5)
        0x91, 0x02,       //   Output (Data, Variable, Absolute)
        // Padding (3 bits)
        0x75, 0x03,       //   Report Size (3)
        0x95, 0x01,       //   Report Count (1)
        0x91, 0x01,       //   Output (Constant)
        0xC0,             // End Collection

        // ---- Consumer Control (Report ID 2) ----
        0x05, 0x0C,       // Usage Page (Consumer)
        0x09, 0x01,       // Usage (Consumer Control)
        0xA1, 0x01,       // Collection (Application)
        0x85, 0x02,       //   Report ID (2)
        0x15, 0x00,       //   Logical Minimum (0)
        0x26, 0xFF, 0x03, //   Logical Maximum (0x03FF)
        0x19, 0x00,       //   Usage Minimum (0)
        0x2A, 0xFF, 0x03, //   Usage Maximum (0x03FF)
        0x75, 0x10,       //   Report Size (16)
        0x95, 0x01,       //   Report Count (1)
        0x81, 0x00,       //   Input (Data, Array)
        0xC0,             // End Collection

        // ---- Mouse (Report ID 3) ----
        0x05, 0x01,       // Usage Page (Generic Desktop)
        0x09, 0x02,       // Usage (Mouse)
        0xA1, 0x01,       // Collection (Application)
        0x85, 0x03,       //   Report ID (3)
        0x09, 0x01,       //   Usage (Pointer)
        0xA1, 0x00,       //   Collection (Physical)
        // Buttons 1-3
        0x05, 0x09,       //     Usage Page (Buttons)
        0x19, 0x01,       //     Usage Minimum (Button 1)
        0x29, 0x03,       //     Usage Maximum (Button 3)
        0x15, 0x00,       //     Logical Minimum (0)
        0x25, 0x01,       //     Logical Maximum (1)
        0x95, 0x03,       //     Report Count (3)
        0x75, 0x01,       //     Report Size (1)
        0x81, 0x02,       //     Input (Data, Variable, Absolute)
        // Padding (5 bits)
        0x95, 0x01,       //     Report Count (1)
        0x75, 0x05,       //     Report Size (5)
        0x81, 0x01,       //     Input (Constant)
        // X, Y (relative, -127..127)
        0x05, 0x01,       //     Usage Page (Generic Desktop)
        0x09, 0x30,       //     Usage (X)
        0x09, 0x31,       //     Usage (Y)
        0x15, 0x81,       //     Logical Minimum (-127)
        0x25, 0x7F,       //     Logical Maximum (127)
        0x75, 0x08,       //     Report Size (8)
        0x95, 0x02,       //     Report Count (2)
        0x81, 0x06,       //     Input (Data, Variable, Relative)
        // Wheel (relative, -127..127)
        0x09, 0x38,       //     Usage (Wheel)
        0x15, 0x81,       //     Logical Minimum (-127)
        0x25, 0x7F,       //     Logical Maximum (127)
        0x75, 0x08,       //     Report Size (8)
        0x95, 0x01,       //     Report Count (1)
        0x81, 0x06,       //     Input (Data, Variable, Relative)
    ]

    /// Optional AC Pan block spliced into the mouse collection when
    /// includeHorizontalScroll is set — macOS maps it to horizontal wheel
    /// on generic mice (tilt-wheel convention).
    private static let acPanBlock: [UInt8] = [
        0x05, 0x0C,       //     Usage Page (Consumer)
        0x0A, 0x38, 0x02, //     Usage (AC Pan)
        0x15, 0x81,       //     Logical Minimum (-127)
        0x25, 0x7F,       //     Logical Maximum (127)
        0x75, 0x08,       //     Report Size (8)
        0x95, 0x01,       //     Report Count (1)
        0x81, 0x06,       //     Input (Data, Variable, Relative)
    ]

    private static let descriptorEnd: [UInt8] = [
        0xC0,             //   End Collection
        0xC0              // End Collection
    ]
}
