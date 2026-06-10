import Foundation
import ServiceManagement

final class AppPreferences {
    static let shared = AppPreferences()

    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: [
            Constants.Defaults.forwardingEnabled: true,
        ])
    }

    /// Backed by SMAppService so the toggle reflects and controls the real login item.
    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                Log.app.error("Launch at login update failed: \(error.localizedDescription)")
            }
        }
    }

    var forwardingEnabled: Bool {
        get { defaults.bool(forKey: Constants.Defaults.forwardingEnabled) }
        set { defaults.set(newValue, forKey: Constants.Defaults.forwardingEnabled) }
    }

    var globalForwardingEnabled: Bool {
        get { defaults.bool(forKey: Constants.Defaults.globalForwardingEnabled) }
        set { defaults.set(newValue, forKey: Constants.Defaults.globalForwardingEnabled) }
    }

    var trackpadScrollEnabled: Bool {
        get { defaults.bool(forKey: Constants.Defaults.trackpadScrollEnabled) }
        set { defaults.set(newValue, forKey: Constants.Defaults.trackpadScrollEnabled) }
    }
}
