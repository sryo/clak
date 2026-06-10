import SwiftUI

extension View {
    @ViewBuilder
    func windowResizeAnchorCompat(_ anchor: UnitPoint) -> some View {
        if #available(macOS 26, *) {
            self.windowResizeAnchor(anchor)
        } else {
            self
        }
    }
}

@main
struct ClakApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Window("Clak", id: "main") {
            MainView(appState: appDelegate.appState, bluetoothManager: appDelegate.bluetoothManager)
            .windowResizeAnchorCompat(.topLeading)
        }
        .windowResizability(.contentSize)

        Settings {
            PreferencesView()
        }
    }
}
