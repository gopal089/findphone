import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var hunt: HuntEngine
    @EnvironmentObject private var beacon: MacBeacon

    /// The exact name of the device to find (remembered between launches).
    @AppStorage("targetName") private var targetName = ""
    /// The name the user has confirmed they own. Changing `targetName`
    /// automatically un-confirms, because the two no longer match.
    @AppStorage("ownedName") private var ownedName = ""
    @AppStorage("soundOn") private var soundOn = false

    @State private var pairedNames: [String] = []
    @State private var notice: String?
    @State private var clicker: Clicker? = Clicker()
    @StateObject private var sweep = DirectionSweep()
    /// Presses of the Control Center "Find iPhone" button.
    @ObservedObject private var controlRequests = ControlRequests.shared

    private var isOwned: Bool {
        !targetName.isEmpty && ownedName == targetName
    }

    var body: some View {
        HStack(alignment: .top, spacing: 22) {
            VStack(alignment: .leading, spacing: 18) {
                deviceSection
                statsCard
                beaconSection
            }
            .frame(width: 360)

            Divider()

            VStack(spacing: 14) {
                SignalGauge(rssi: hunt.currentSignal, strongest: hunt.strongest?.rssi)
                    .frame(height: 300)
                directionSection
            }
            .frame(width: 470)
        }
        .padding(22)
        .onAppear {
            wireSound()
            PairedDevices.loadNames { pairedNames = $0 }
            // A soft "pop" when it's time to turn, so you don't need to watch the screen.
            sweep.onStepChange = { NSSound(named: "Pop")?.play() }
        }
        .onChange(of: soundOn) { _ in wireSound() }
        .onChange(of: hunt.target) { target in
            if target == nil { sweep.cancel() }
        }
        .onOpenURL(perform: handleURL)
        // Also fires right away if the button launched the app.
        .onReceive(controlRequests.$pendingHunt) { pending in
            if pending && controlRequests.takePendingHunt() {
                startFromControlCenter()
            }
        }
    }

    // MARK: - Left column: choose and confirm the device

    private var deviceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("findphone", systemImage: "iphone.radiowaves.left.and.right")
                .font(.title.bold())

            Text("Find my iPhone nearby")
                .foregroundStyle(.secondary)

            HStack {
                TextField("Exact device name", text: $targetName)
                    .textFieldStyle(.roundedBorder)
                Menu("Paired devices") {
                    if pairedNames.isEmpty {
                        Text("No paired devices found")
                    }
                    ForEach(pairedNames, id: \.self) { name in
                        Button(name) { targetName = name }
                    }
                }
                .fixedSize()
            }
            .disabled(hunt.isHunting)

            Toggle("This device is mine (required before searching)", isOn: Binding(
                get: { isOwned },
                set: { ownedName = $0 ? targetName : "" }
            ))
            .disabled(hunt.isHunting || targetName.isEmpty)

            Toggle("Click faster as I get closer", isOn: $soundOn)

            if hunt.isHunting {
                Button(role: .cancel) { hunt.stop() } label: {
                    Label("Stop search", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)
            } else {
                Button { startSearch() } label: {
                    Label("Start search", systemImage: "dot.radiowaves.left.and.right")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!isOwned)
            }

            Text(hunt.status)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            if let notice {
                Text(notice).foregroundStyle(.orange)
            }
        }
    }

    private var statsCard: some View {
        TimelineView(.periodic(from: .now, by: 0.33)) { context in
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                stat("antenna.radiowaves.left.and.right", "Source", hunt.latest?.source.rawValue ?? "none yet")
                stat("waveform", "Latest", latestText(now: context.date))
                stat("star.fill", "Strongest", strongestText())
                stat("timer", "Elapsed", elapsedText(now: context.date))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
        }
    }

    private func stat(_ symbol: String, _ label: String, _ value: String) -> some View {
        GridRow {
            Image(systemName: symbol).foregroundStyle(.secondary)
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
    }

    private func latestText(now: Date) -> String {
        guard let latest = hunt.latest else { return "none yet" }
        let age = now.timeIntervalSince(latest.time)
        return "\(latest.rssi) dBm, \(String(format: "%.1f", age)) s ago"
    }

    private func strongestText() -> String {
        guard let best = hunt.strongest, let started = hunt.startedAt else { return "none yet" }
        let when = SignalMath.clock(best.time.timeIntervalSince(started))
        return "\(best.rssi) dBm at \(when)"
    }

    private func elapsedText(now: Date) -> String {
        guard let started = hunt.startedAt else { return "00:00" }
        return SignalMath.clock((hunt.endedAt ?? now).timeIntervalSince(started))
    }

    // MARK: - Beacon (lets the iPhone app find this Mac)

    private var beaconSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Let my iPhone find this Mac (beacon)", isOn: Binding(
                get: { beacon.isOn },
                set: { beacon.setOn($0) }
            ))
            Text(beacon.status)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Works only while this Mac is awake, this app is open, and the iPhone is in Bluetooth range. Nearby scanners can see that a findphone beacon exists, so turn it off when you don't need it. For a truly lost Mac, use Find My.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Right column: direction

    /// What the 3D arrow and headline should show right now.
    private struct DirectionDisplay {
        var rotation: Double
        var color: Color
        var isActive: Bool
        var title: String
        var detail: String
    }

    private func directionDisplay(now: Date) -> DirectionDisplay {
        // 1. During a sweep: which way you face, compared with step 1.
        switch sweep.phase {
        case .turning(let heading, _), .measuring(let heading, _):
            return DirectionDisplay(rotation: Double(heading.rawValue) * 90, color: .blue, isActive: true,
                                    title: "Facing \(heading.shortName.lowercased())",
                                    detail: "Compared with the way you faced in step 1.")
        // 2. A clear sweep result.
        case .finished(let estimate?) where estimate.confidence != .unclear:
            return DirectionDisplay(rotation: Double(estimate.best.rawValue) * 90,
                                    color: estimate.confidence == .strong ? .green : .mint,
                                    isActive: true,
                                    title: "Most likely \(estimate.best.name)",
                                    detail: confidenceText(estimate))
        default:
            break
        }

        // 3. Otherwise, the live closer/farther trend while walking.
        let trend: Trend = hunt.isHunting
            ? DirectionMath.trend(hunt.history.map { (rssi: $0.rssi, time: $0.time) }, now: now)
            : .unknown
        switch trend {
        case .closer(let dB):
            return DirectionDisplay(rotation: 0, color: .green, isActive: true,
                                    title: "Getting closer",
                                    detail: "+\(dB) dB in the last few seconds. Keep going this way.")
        case .farther(let dB):
            return DirectionDisplay(rotation: 180, color: .orange, isActive: true,
                                    title: "Turn around",
                                    detail: "−\(dB) dB in the last few seconds. You're moving away.")
        case .steady:
            return DirectionDisplay(rotation: 0, color: .yellow, isActive: false,
                                    title: "About the same",
                                    detail: "Try another direction, or use Find direction.")
        case .unknown:
            return DirectionDisplay(rotation: 0, color: .gray, isActive: false,
                                    title: hunt.isHunting ? "Walk a few steps" : "No direction yet",
                                    detail: hunt.isHunting
                                        ? "findphone needs a few seconds of movement to see a trend."
                                        : "Start a search to see direction hints.")
        }
    }

    private var directionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                let display = directionDisplay(now: context.date)
                HStack(spacing: 14) {
                    DirectionArrow3D(rotation: display.rotation, color: display.color, isActive: display.isActive)
                        .frame(width: 210, height: 160)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(display.title)
                            .font(.system(.title2, design: .rounded).bold())
                            .foregroundStyle(display.isActive ? display.color : .primary)
                        Text(display.detail)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            sweepControls

            Text("Bluetooth can't sense direction directly. findphone estimates it from whether the signal rises or falls as you walk, and by comparing the signal as you turn, because your body blocks some of the signal from behind you.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The guided four-direction sweep.
    @ViewBuilder
    private var sweepControls: some View {
        switch sweep.phase {
        case .idle:
            Button { sweep.start(using: hunt) } label: {
                Label("Find direction (turn on the spot, about \(DirectionSweep.totalSeconds) s)",
                      systemImage: "location.north.circle")
            }
            .controlSize(.large)
            .disabled(hunt.currentSignal == nil)

        case .turning(let heading, let secondsLeft):
            sweepStep(title: heading.instruction,
                      detail: "Measuring starts in \(secondsLeft)…",
                      progress: 0)

        case .measuring(let heading, let secondsLeft):
            sweepStep(title: "Hold still, facing \(heading.shortName.lowercased()).",
                      detail: "Measuring… \(secondsLeft) s",
                      progress: Double(DirectionSweep.measureSeconds - secondsLeft) / Double(DirectionSweep.measureSeconds))

        case .finished(let estimate):
            sweepResult(estimate)
        }
    }

    private func sweepStep(title: String, detail: String, progress: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Step \(sweep.stepNumber) of \(Heading.allCases.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                ProgressView(value: progress)
                Text(detail)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Button("Cancel") { sweep.cancel() }
        }
    }

    @ViewBuilder
    private func sweepResult(_ estimate: DirectionEstimate?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let estimate {
                HStack(spacing: 22) {
                    ForEach(Heading.allCases) { heading in
                        VStack(spacing: 2) {
                            Image(systemName: heading.arrowSymbol)
                                .foregroundStyle(heading == estimate.best && estimate.confidence != .unclear
                                                 ? Color.green : Color.secondary)
                            Text(heading.shortName).font(.caption)
                            Text(estimate.medians[heading].map { "\($0) dBm" } ?? "–")
                                .font(.caption.monospacedDigit())
                                .fontWeight(heading == estimate.best ? .bold : .regular)
                        }
                    }
                }
                Text(estimate.confidence == .unclear
                     ? "No clear direction: \(confidenceText(estimate)) Try again from a different spot, or walk and follow the arrow."
                     : "Make one more quarter-turn right to face your step-1 direction, turn toward the arrow, and walk.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Not enough signal readings to estimate a direction. Make sure the speedometer shows a signal, then try again.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Try again") { sweep.start(using: hunt) }
                    .disabled(hunt.currentSignal == nil)
                Button("Done") { sweep.cancel() }
            }
        }
    }

    private func confidenceText(_ estimate: DirectionEstimate) -> String {
        switch estimate.confidence {
        case .strong: return "Strong: \(estimate.margin) dB above the next direction."
        case .likely: return "Likely: \(estimate.margin) dB above the next direction."
        case .unclear: return "the directions differed by only \(estimate.margin) dB, which is normal noise."
        }
    }

    // MARK: - Actions

    private func startSearch() {
        notice = nil
        hunt.start(.named(targetName), ownershipConfirmed: isOwned)
    }

    /// Sound on: hand every signal update to the clicker. Sound off: silence.
    private func wireSound() {
        if soundOn, let clicker {
            hunt.onSignalUpdate = { clicker.update(rssi: $0) }
        } else {
            hunt.onSignalUpdate = nil
            clicker?.update(rssi: nil)
        }
        if soundOn && clicker == nil {
            notice = "Couldn't load the click sound."
        }
    }

    /// findphone://hunt links do the same as the Control Center button.
    private func handleURL(_ url: URL) {
        guard url.scheme == "findphone", url.host == "hunt" else { return }
        startFromControlCenter()
    }

    /// Starts a search only for a device you've already confirmed is yours.
    private func startFromControlCenter() {
        controlLog.notice("Window got the button press; device confirmed as yours: \(isOwned, privacy: .public)")
        // macOS opens the app in the background for this action, so bring
        // the window to the front where you can see it.
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.windows.first { $0.isVisible || $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        guard isOwned else {
            notice = "Choose your device and tick \"This device is mine\", then press Start search."
            return
        }
        if !hunt.isHunting {
            startSearch()
        }
    }
}
