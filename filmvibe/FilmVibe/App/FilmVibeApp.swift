import SwiftUI

@main
struct FilmVibeApp: App {
    @StateObject private var app = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            CameraScreen(camera: app.camera)
                .environmentObject(app)
                .environmentObject(app.recipes)
                .environmentObject(app.tuning)
                .environmentObject(app.library)
                .environmentObject(app.settings)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .statusBarHidden()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: app.camera.start()
            case .background: app.camera.stop()
            default: break
            }
        }
    }
}
