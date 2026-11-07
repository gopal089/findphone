import Foundation
import AudioToolbox

/// Geiger-counter style clicks: the macOS "Tink" sound, faster as the
/// signal gets stronger (same mapping as the command-line --sound flag).
/// `update(rssi: nil)` means "no current signal" and stops the clicks.
final class Clicker {

    static let soundPath = "/System/Library/Sounds/Tink.aiff"

    private let soundID: SystemSoundID
    private var interval: TimeInterval?
    private var lastClick: Date?
    private var timer: Timer?

    /// Loads Tink.aiff, or returns nil if it can't be loaded.
    init?() {
        let url = URL(fileURLWithPath: Self.soundPath)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var id: SystemSoundID = 0
        guard AudioServicesCreateSystemSoundID(url as CFURL, &id) == kAudioServicesNoError else { return nil }
        soundID = id
    }

    deinit {
        timer?.invalidate()
        AudioServicesDisposeSystemSoundID(soundID)
    }

    func update(rssi: Int?) {
        guard let rssi else {
            interval = nil
            timer?.invalidate()
            timer = nil
            return
        }
        let newInterval = SignalMath.clickInterval(for: rssi)
        guard newInterval != interval else { return }
        interval = newInterval
        scheduleNextClick()
    }

    private func scheduleNextClick() {
        timer?.invalidate()
        guard let interval else {
            timer = nil
            return
        }
        let due = (lastClick ?? .distantPast).addingTimeInterval(interval)
        let delay = max(0, due.timeIntervalSinceNow)
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.click()
        }
    }

    private func click() {
        AudioServicesPlaySystemSound(soundID)
        lastClick = Date()
        scheduleNextClick()
    }
}
