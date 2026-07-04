import SwiftUI

@main
struct ClakRemoteApp: App {
    @State private var controller = RemoteController()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(controller: controller)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                controller.sceneDidBecomeActive()
            case .background:
                controller.sceneDidEnterBackground()
            default:
                break
            }
        }
    }
}
