import SwiftUI

@Observable
final class AppState {
    var isForwarding = AppPreferences.shared.forwardingEnabled
    var isGlobalForwarding = AppPreferences.shared.globalForwardingEnabled
    /// The echo line, published at most once per frame from `echo`.
    private(set) var typedText = ""
    var connectedDeviceName: String?
    var isConnected = false
    var capsLockActive = false
    var needsInputMonitoring = false
    var needsAccessibility = false
    var errorMessage: String?
    var bluetooth: BluetoothAvailability = .on
    /// True while a central is connected but still pairing, i.e. the Mac is
    /// showing the Numeric Comparison dialog.
    var isAwaitingPairingConfirmation = false

    static let echoFrameInterval: TimeInterval = 1.0 / 60

    @ObservationIgnored private var echo = EchoBuffer()
    @ObservationIgnored private var echoIsDirty = false
    @ObservationIgnored private var echoPublish: TickThrottle!

    init(echoScheduler: TickScheduler = MainQueueTickScheduler.shared) {
        echoPublish = TickThrottle(interval: Self.echoFrameInterval, leading: false, scheduler: echoScheduler) { [weak self] in
            self?.publishEcho()
        }
    }

    func appendText(_ text: String) {
        echo.append(text)
        echoChanged()
    }

    func removeLastCharacter() {
        guard !echo.text.isEmpty else {
            return
        }
        echo.removeLast()
        echoChanged()
    }

    func clearText() {
        echo.removeAll()
        echoIsDirty = false
        if !typedText.isEmpty {
            typedText = ""
        }
    }

    private func echoChanged() {
        echoIsDirty = true
        echoPublish.request()
    }

    private func publishEcho() {
        guard echoIsDirty else { return }
        echoIsDirty = false
        typedText = echo.text
    }
}
