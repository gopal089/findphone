import AppIntents
import Foundation
import os

/// Log messages for the Control Center button. View them with:
///   /usr/bin/log show --last 10m --predicate 'subsystem == "local.findphone"'
let controlLog = Logger(subsystem: "local.findphone", category: "control")

/// The action behind the Control Center "Find iPhone" button.
///
/// This file is built into BOTH the app and the button extension:
/// - the extension needs it so macOS can show the button, and
/// - the app needs it because `openAppWhenRun` makes macOS open findphone
///   and run `perform()` inside the app.
///
/// `perform()` only passes the request to the window. The window then starts
/// a search only if you've already ticked "This device is mine".
struct OpenFindPhoneIntent: AppIntent {
    static var title: LocalizedStringResource = "Find iPhone"
    static var description = IntentDescription("Opens findphone and starts searching for the iPhone you confirmed is yours.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        controlLog.notice("OpenFindPhoneIntent.perform ran in \(Bundle.main.bundleIdentifier ?? "?", privacy: .public)")
        ControlRequests.shared.requestHunt()
        return .result()
    }
}

/// Carries "the Control Center button was pressed" from the intent to the
/// app's window. (Built into the extension too, where it's simply unused.)
@MainActor
final class ControlRequests: ObservableObject {
    static let shared = ControlRequests()

    @Published private(set) var pendingHunt = false

    func requestHunt() {
        pendingHunt = true
    }

    /// Returns true once per button press, then resets.
    func takePendingHunt() -> Bool {
        guard pendingHunt else { return false }
        pendingHunt = false
        return true
    }
}
