import Foundation
import AudioToolbox

/// Geiger-counter style clicker for hunt mode (`--sound`).
///
/// Give it the smoothed RSSI with `update(rssi:)` and it plays the macOS
/// "Tink" sound faster as the signal gets stronger:
///
///     -95 dBm or weaker   ->  1 click per second
///     -50 dBm or stronger ->  1 click every 0.07 seconds
///     in between          ->  a straight line between those two
///
/// Passing `nil` stops the clicks, so silence means "no current signal".
/// The clicker runs its own timer, separate from the screen refresh.
final class Clicker {

    static let soundPath = "/System/Library/Sounds/Tink.aiff"

    static let weakRSSI = -95.0
    static let strongRSSI = -50.0
    static let slowestInterval: TimeInterval = 1.0    // at weakRSSI and below
    static let fastestInterval: TimeInterval = 0.07   // at strongRSSI and above

    /// The ID macOS gives us for the loaded sound.
    private let soundID: SystemSoundID

    /// Time between clicks right now, or nil when silent.
    private(set) var interval: TimeInterval?
    private var lastClick: Date?
    private var timer: Timer?

    /// Loads Tink.aiff. Returns nil if the sound can't be loaded.
    init?() {
        let url = URL(fileURLWithPath: Self.soundPath)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        var id: SystemSoundID = 0
        let status = AudioServicesCreateSystemSoundID(url as CFURL, &id)
        guard status == kAudioServicesNoError else { return nil }
        soundID = id
    }

    deinit {
        timer?.invalidate()
        // Give the sound back to macOS.
        AudioServicesDisposeSystemSoundID(soundID)
    }

    /// Converts signal strength to seconds between clicks.
    static func interval(for rssi: Int) -> TimeInterval {
        // Clamp so anything weaker than -95 or stronger than -50 stays at the ends.
        let clamped = min(max(Double(rssi), weakRSSI), strongRSSI)
        // 0.0 at -95 dBm, 1.0 at -50 dBm.
        let fraction = (clamped - weakRSSI) / (strongRSSI - weakRSSI)
        return slowestInterval + (fastestInterval - slowestInterval) * fraction
    }

    /// Sets the signal to click for. `nil` means no current signal: stay silent.
    func update(rssi: Int?) {
        guard let rssi else {
            interval = nil
            timer?.invalidate()
            timer = nil
            return
        }
        let newInterval = Self.interval(for: rssi)
        guard newInterval != interval else { return }
        interval = newInterval
        scheduleNextClick()
    }

    /// Schedules the next click `interval` seconds after the previous one
    /// (or right away if that time has already passed), so a stronger signal
    /// speeds the clicks up immediately instead of after a slow click.
    private func scheduleNextClick() {
        timer?.invalidate()
        guard let interval else {
            timer = nil
            return
        }
        let due = (lastClick ?? .distantPast).addingTimeInterval(interval)
        let delay = max(0, due.timeIntervalSinceNow)
        // `[weak self]` so the timer doesn't keep the Clicker alive forever;
        // that lets deinit run and dispose the sound.
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
