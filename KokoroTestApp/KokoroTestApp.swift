import SwiftUI

/// The main application entry point for the Kokoro TTS test app.
/// This app demonstrates the Kokoro text-to-speech engine with MLX acceleration.
@main
struct KokoroTestApp: App {
    /// The main view model that manages the TTS engine and application state
    let model = TestAppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: model)
        }
    }
}
