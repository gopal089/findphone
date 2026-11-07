import SwiftUI

/// The findphone Mac app: one window for finding your iPhone, plus a switch
/// that lets your iPhone find this Mac.
@main
struct FindPhoneApp: App {
    @StateObject private var hunt = HuntEngine()
    @StateObject private var beacon = MacBeacon()

    var body: some Scene {
        Window("findphone", id: "main") {
            ContentView()
                .environmentObject(hunt)
                .environmentObject(beacon)
        }
        .windowResizability(.contentSize)
    }
}
