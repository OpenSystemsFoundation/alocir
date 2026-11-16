import AlocirCore
import SwiftUI

@main
struct AlocirApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

/// Milestone 0 placeholder. Milestone 4 replaces it with the start screen.
struct ContentView: View {
    var body: some View {
        Text("Alocir")
            .frame(minWidth: 480, minHeight: 320)
    }
}
