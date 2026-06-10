import SwiftUI

@main
struct ClakRemoteApp: App {
    @State private var controller = RemoteController()

    var body: some Scene {
        WindowGroup {
            ContentView(controller: controller)
        }
    }
}
