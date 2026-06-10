import Foundation

enum Constants {
    static let appName = "Clak"
    static let bundleIdentifier = "com.clak.app"

    // MARK: - Paste
    enum AutoConnect {
        /// Minimum delay between keystrokes during paste (seconds)
        static let pasteKeystrokeDelay: TimeInterval = 0.01
    }

    // MARK: - Trackpad
    enum Trackpad {
        /// Multiplier applied to pad drag deltas before sending mouse reports
        static let sensitivity: CGFloat = 1.6
        /// Total drag distance (points) under which a press-release counts as a tap
        static let tapThreshold: CGFloat = 3
        /// Minimum interval between mouse move reports (coalesces 120Hz input to BLE-friendly rate)
        static let moveReportInterval: TimeInterval = 0.008
    }

    // MARK: - UserDefaults Keys
    enum Defaults {
        static let forwardingEnabled = "forwardingEnabled"
        static let globalForwardingEnabled = "globalForwardingEnabled"
        static let trackpadScrollEnabled = "trackpadScrollEnabled"
    }
}
