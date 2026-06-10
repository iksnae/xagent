import SwiftUI

/// The main entry point for the XAgent SwiftUI control application.
/// Provides a minimal UI to submit tasks and stream events from the
/// xagentd HTTP API (default: localhost:8080).
@main
struct XAgentApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
