import AppIntents
import SwiftUI
import WidgetKit

/// The extension's entry point: the list of controls it offers.
@main
struct FindPhoneMacControls: WidgetBundle {
    var body: some Widget {
        FindIPhoneControl()
    }
}

/// A "Find iPhone" button for Control Center and the menu bar.
///
/// Control Center buttons can't scan for Bluetooth themselves, so this one
/// runs `OpenFindPhoneIntent` (in Apps/Intents), which opens the findphone
/// app. The app then starts searching, but only for a device you've already
/// confirmed is yours.
struct FindIPhoneControl: ControlWidget {
    static let kind = "local.findphone.mac.find-iphone"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OpenFindPhoneIntent()) {
                Label("Find iPhone", systemImage: "iphone.radiowaves.left.and.right")
            }
        }
        .displayName("Find iPhone")
        .description("Opens findphone and searches for the iPhone you confirmed is yours.")
    }
}
