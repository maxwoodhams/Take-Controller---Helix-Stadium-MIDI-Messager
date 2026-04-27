import SwiftUI

@main
struct HelixMIDIApp: App {
    @StateObject private var store = ControllerStore()
    @StateObject private var midi = MIDIManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(midi)
        }
    }
}
