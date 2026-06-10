import SwiftUI

@Observable
final class AppState {
    var isForwarding = AppPreferences.shared.forwardingEnabled
    var isGlobalForwarding = AppPreferences.shared.globalForwardingEnabled
    var typedText = ""
    var connectedDeviceName: String?
    var isConnected = false
    var capsLockActive = false
    var needsInputMonitoring = false
    var needsAccessibility = false
    var errorMessage: String?

    func appendText(_ text: String) {
        typedText += text
        // Keep last 5000 characters
        if typedText.count > 5000 {
            typedText = String(typedText.suffix(5000))
        }
    }

    func removeLastCharacter() {
        guard !typedText.isEmpty else {
            return
        }
        typedText.removeLast()
    }

    func clearText() {
        typedText = ""
    }
}
