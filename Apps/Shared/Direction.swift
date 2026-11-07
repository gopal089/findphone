import Foundation

// DIRECTION FINDING
//
// Bluetooth signal strength (RSSI) can't measure direction by itself, and a
// Mac has no Ultra-Wideband chip or compass. findphone estimates direction
// in two ways instead:
//
// 1. Trend: as you walk, is the signal rising (closer) or falling (farther)?
// 2. Sweep: you turn on the spot in four quarter-turns while holding the Mac
//    in front of your chest. Your body blocks some of the signal coming from
//    behind you, so the signal is usually strongest when you face the phone.
//
// Directions are relative to the way you faced at the start of the sweep.

/// One of the four directions in a sweep, relative to step 1.
enum Heading: Int, CaseIterable, Identifiable {
    case ahead, right, behind, left

    var id: Int { rawValue }

    /// "Most likely ___"
    var name: String {
        switch self {
        case .ahead: return "straight ahead"
        case .right: return "to your right"
        case .behind: return "behind you"
        case .left: return "to your left"
        }
    }

    var shortName: String {
        switch self {
        case .ahead: return "Ahead"
        case .right: return "Right"
        case .behind: return "Behind"
        case .left: return "Left"
        }
    }

    /// SF Symbol for the arrow.
    var arrowSymbol: String {
        switch self {
        case .ahead: return "arrow.up"
        case .right: return "arrow.right"
        case .behind: return "arrow.down"
        case .left: return "arrow.left"
        }
    }

    /// What to do before measuring this direction.
    var instruction: String {
        switch self {
        case .ahead:
            return "Hold the Mac in front of your chest and face any direction. This is \"ahead\"."
        case .right, .behind, .left:
            return "Turn a quarter-turn to your RIGHT (90°)."
        }
    }
}

/// Whether the signal is rising or falling as you move.
enum Trend: Equatable {
    case closer(Int)    // dB gained
    case farther(Int)   // dB lost
    case steady
    case unknown        // not enough recent readings
}

enum Confidence {
    case strong, likely, unclear
}

/// The result of a sweep.
struct DirectionEstimate: Equatable {
    /// Median RSSI measured while facing each direction.
    let medians: [Heading: Int]
    let best: Heading
    /// How many dB the best direction beat the runner-up by.
    let margin: Int

    var confidence: Confidence {
        if margin >= 6 { return .strong }
        if margin >= 3 { return .likely }
        return .unclear
    }
}

enum DirectionMath {
    /// Trend compares the median of the last 3 s with the 3 s before that.
    static let trendWindow: TimeInterval = 3
    /// A change smaller than this many dB counts as "steady" (normal noise).
    static let trendThreshold = 3
    static let minReadingsPerTrendWindow = 3
    /// A sweep direction needs at least this many readings to count.
    static let minReadingsPerHeading = 4

    static func trend(_ samples: [(rssi: Int, time: Date)], now: Date) -> Trend {
        let recent = samples
            .filter { now.timeIntervalSince($0.time) <= trendWindow }
            .map { $0.rssi }
        let earlier = samples
            .filter {
                let age = now.timeIntervalSince($0.time)
                return age > trendWindow && age <= 2 * trendWindow
            }
            .map { $0.rssi }

        guard recent.count >= minReadingsPerTrendWindow,
              earlier.count >= minReadingsPerTrendWindow,
              let now = SignalMath.median(of: recent),
              let before = SignalMath.median(of: earlier) else {
            return .unknown
        }
        let change = now - before
        if change >= trendThreshold { return .closer(change) }
        if change <= -trendThreshold { return .farther(-change) }
        return .steady
    }

    /// Picks the strongest direction. Needs at least 3 measured directions.
    static func estimate(_ medians: [Heading: Int]) -> DirectionEstimate? {
        guard medians.count >= 3 else { return nil }
        let ranked = medians.sorted { $0.value > $1.value }
        return DirectionEstimate(medians: medians,
                                 best: ranked[0].key,
                                 margin: ranked[0].value - ranked[1].value)
    }
}

/// Runs the guided four-direction sweep: for each direction, a few seconds
/// to turn, then a few seconds of measuring while standing still.
final class DirectionSweep: ObservableObject {

    enum Phase: Equatable {
        case idle
        case turning(Heading, secondsLeft: Int)
        case measuring(Heading, secondsLeft: Int)
        case finished(DirectionEstimate?)   // nil: not enough readings
    }

    static let turnSeconds = 3
    static let measureSeconds = 5
    static var totalSeconds: Int { (turnSeconds + measureSeconds) * Heading.allCases.count }

    @Published private(set) var phase: Phase = .idle

    /// Called when it's time to turn and when the sweep finishes (for a sound).
    var onStepChange: (() -> Void)?

    private weak var hunt: HuntEngine?
    private var timer: Timer?
    private var stepIndex = 0
    private var secondsLeft = 0
    private var measureStart = Date()
    private var medians: [Heading: Int] = [:]

    var stepNumber: Int { stepIndex + 1 }

    var isRunning: Bool {
        switch phase {
        case .turning, .measuring: return true
        default: return false
        }
    }

    func start(using hunt: HuntEngine) {
        cancel()
        self.hunt = hunt
        medians = [:]
        stepIndex = 0
        beginTurning()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        phase = .idle
    }

    private var heading: Heading { Heading.allCases[stepIndex] }

    private func beginTurning() {
        secondsLeft = Self.turnSeconds
        phase = .turning(heading, secondsLeft: secondsLeft)
        onStepChange?()
    }

    private func tick() {
        secondsLeft -= 1
        switch phase {
        case .turning:
            if secondsLeft > 0 {
                phase = .turning(heading, secondsLeft: secondsLeft)
            } else {
                // Readings taken while turning are ignored; measuring starts now.
                secondsLeft = Self.measureSeconds
                measureStart = Date()
                phase = .measuring(heading, secondsLeft: secondsLeft)
            }

        case .measuring:
            if secondsLeft > 0 {
                phase = .measuring(heading, secondsLeft: secondsLeft)
                return
            }
            let readings = (hunt?.history ?? [])
                .filter { $0.time >= measureStart }
                .map { $0.rssi }
            if readings.count >= DirectionMath.minReadingsPerHeading,
               let median = SignalMath.median(of: readings) {
                medians[heading] = median
            }
            if stepIndex + 1 < Heading.allCases.count {
                stepIndex += 1
                beginTurning()
            } else {
                timer?.invalidate()
                timer = nil
                phase = .finished(DirectionMath.estimate(medians))
                onStepChange?()
            }

        case .idle, .finished:
            break
        }
    }
}
