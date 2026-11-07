import Foundation
import CoreBluetooth

/// HUNT MODE.
///
/// Tracks one device that the user has confirmed they own (with --owned),
/// matched by its exact name (upper/lower case may differ). Shows its signal
/// strength as large digits so you can walk toward it.
///
/// Signal sources, in order of preference:
///   1. "connected link"  - a plain BLE connection to the target, reading RSSI
///                          every 0.3 s. No services are discovered and nothing
///                          is read from the device, so this never pairs.
///   2. "advertisement"   - the RSSI of the target's broadcasts, used while
///                          finding or connecting to it.
///   3. "paired fallback" - if BLE has been quiet for a few seconds, the
///                          signal macOS reports for an already-paired device
///                          (read from system_profiler; never pairs).
final class Hunter: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {

    enum Source: String {
        case advertisement = "advertisement"
        case connectedLink = "connected link"
        case pairedFallback = "paired fallback"
    }

    private struct Reading {
        let rssi: Int
        let source: Source
        let time: Date
    }

    // MARK: Settings

    /// Readings outside this range are errors or "no value" markers (127, 0).
    static let validRSSI = -126 ... -1
    /// The displayed value is the median of this many newest readings.
    private let windowSize = 7
    private let rssiInterval: TimeInterval = 0.3
    private let screenInterval: TimeInterval = 0.33
    /// How often to consider the paired fallback, and after how much BLE silence.
    private let fallbackCheckInterval: TimeInterval = 2
    private let fallbackAfter: TimeInterval = 5
    /// Give up on a connection attempt after this long and try again later.
    private let connectTimeout: TimeInterval = 10
    /// With --sound, go silent after this long without a valid target reading.
    private let soundSilenceAfter: TimeInterval = 10

    // MARK: State

    private let targetName: String
    private var central: CBCentralManager!

    /// The one peripheral we matched by name. CoreBluetooth requires us to
    /// keep a strong reference while connecting or connected.
    private var target: CBPeripheral?
    private var connectStartedAt: Date?

    private var statusLine = "Checking Bluetooth status..."
    private var fallbackNote: String?

    private var recent: [Reading] = []        // newest last, at most `windowSize`
    private var strongest: Reading?
    private var lastBLEReadingAt: Date?
    private var fallbackQueryRunning = false

    private let startedAt = Date()
    private var screenTimer: Timer?
    private var rssiTimer: Timer?
    private var fallbackTimer: Timer?

    private let isTerminal = isatty(STDOUT_FILENO) != 0

    /// Plays clicks for --sound; nil when sound is off.
    private let clicker: Clicker?

    /// With --redact, the only name printed is the one the user typed;
    /// identifiers print as "hidden" and system error details are left out.
    private let redact: Bool

    init(targetName: String, clicker: Clicker? = nil, redact: Bool = false) {
        self.targetName = targetName
        self.clicker = clicker
        self.redact = redact
        super.init()
        // Delegate callbacks arrive on the main queue (kept alive by main.swift).
        central = CBCentralManager(delegate: self, queue: nil)

        screenTimer = Timer.scheduledTimer(timeInterval: screenInterval, target: self,
                                           selector: #selector(tick), userInfo: nil, repeats: true)
        fallbackTimer = Timer.scheduledTimer(timeInterval: fallbackCheckInterval, target: self,
                                             selector: #selector(considerFallback), userInfo: nil, repeats: true)
    }

    // MARK: - Bluetooth state

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard let problem = bluetoothProblem(for: central.state) else {
            startScanning()
            return
        }
        if problem.isFatal {
            screenTimer?.invalidate()
            print("\n" + problem.message)
            exit(1)
        }
        // Bluetooth went away for now; any connection is gone with it.
        dropTarget()
        statusLine = problem.message
    }

    // MARK: - Finding the target

    private func startScanning() {
        guard central.state == .poweredOn else { return }
        statusLine = "Scanning for \"\(targetName)\"..."
        // Every advertisement is checked, but only the exact name match is used.
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let advertisedName = cleanedName(advertisementData[CBAdvertisementDataLocalNameKey] as? String)
        let knownName = cleanedName(peripheral.name)
        let isTarget = [advertisedName, knownName].contains { name in
            name.map { namesMatch($0, targetName) } ?? false
        }
        guard isTarget else { return }

        // If we've already picked a peripheral with this name, ignore others.
        if let current = target, current.identifier != peripheral.identifier { return }

        record(RSSI.intValue, source: .advertisement)

        if target == nil {
            target = peripheral
            peripheral.delegate = self
            connectStartedAt = Date()
            statusLine = "Found it. Connecting (link only, no pairing)..."
            // A plain connection. We never call discoverServices or read
            // characteristics, which is what could make a device ask to pair.
            central.connect(peripheral, options: nil)
        }
    }

    // MARK: - Connection

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral.identifier == target?.identifier else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        connectStartedAt = nil
        central.stopScan()
        statusLine = "Connected (link only, not paired). Reading signal every \(rssiInterval) s."
        rssiTimer?.invalidate()
        rssiTimer = Timer.scheduledTimer(timeInterval: rssiInterval, target: self,
                                         selector: #selector(requestRSSI), userInfo: nil, repeats: true)
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        guard peripheral.identifier == target?.identifier else { return }
        dropTarget()
        // System error text could mention device details, so skip it when redacting.
        let reason = redact ? "details hidden by --redact" : (error?.localizedDescription ?? "unknown reason")
        statusLine = "Couldn't connect (\(reason)). Still listening for it..."
        startScanning()
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        guard peripheral.identifier == target?.identifier else { return }
        dropTarget()
        startScanning()
        statusLine = "Connection lost. Scanning for \"\(targetName)\" again..."
    }

    @objc private func requestRSSI() {
        guard let peripheral = target, peripheral.state == .connected else { return }
        peripheral.readRSSI()
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard error == nil else { return }
        record(RSSI.intValue, source: .connectedLink)
    }

    /// Forgets the current peripheral and stops polling it.
    private func dropTarget() {
        rssiTimer?.invalidate()
        rssiTimer = nil
        if let peripheral = target, central.state == .poweredOn, peripheral.state != .disconnected {
            central.cancelPeripheralConnection(peripheral)
        }
        target = nil
        connectStartedAt = nil
    }

    private func checkConnectTimeout() {
        guard let started = connectStartedAt,
              Date().timeIntervalSince(started) > connectTimeout else { return }
        dropTarget()
        statusLine = "Connection attempt timed out. Still listening to its advertisements..."
        // Scanning is still running, so the next advertisement retries.
    }

    // MARK: - Paired fallback

    @objc private func considerFallback() {
        guard !fallbackQueryRunning, bleIsQuiet() else { return }
        fallbackQueryRunning = true

        // system_profiler takes a second or two, so run it off the main queue
        // to keep the screen responsive, then hand the result back.
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try Classic.pairedDevices() }
            DispatchQueue.main.async {
                self.handleFallback(result)
            }
        }
    }

    private func bleIsQuiet() -> Bool {
        let since = lastBLEReadingAt ?? startedAt
        return Date().timeIntervalSince(since) > fallbackAfter
    }

    private func handleFallback(_ result: Result<[PairedDevice], Error>) {
        fallbackQueryRunning = false
        // BLE may have come back while system_profiler was running.
        guard bleIsQuiet() else { return }

        switch result {
        case .failure(let error):
            fallbackNote = "Paired fallback unavailable: \(error)"
        case .success(let devices):
            guard let device = devices.first(where: { namesMatch($0.name, targetName) }) else {
                fallbackNote = "Paired fallback: \"\(targetName)\" isn't in this Mac's paired list (see --list)."
                return
            }
            guard let rssi = device.rssi else {
                // Show the name as the user typed it when redacting; the
                // paired list's spelling may differ in upper/lower case.
                let shownName = redact ? targetName : device.name
                fallbackNote = "Paired fallback: found \"\(shownName)\" in the paired list, but macOS has no signal reading for it."
                return
            }
            fallbackNote = "Paired fallback: using the signal macOS reports for this paired device. It may update slowly."
            record(rssi, source: .pairedFallback)
        }
    }

    // MARK: - Readings

    /// Stores a reading if it's valid. Switching sources starts a fresh
    /// window so values from different sources aren't mixed in one median.
    private func record(_ rssi: Int, source: Source) {
        guard Self.validRSSI.contains(rssi) else { return }
        let reading = Reading(rssi: rssi, source: source, time: Date())

        if let last = recent.last, last.source != source {
            recent.removeAll()
        }
        recent.append(reading)
        if recent.count > windowSize {
            recent.removeFirst(recent.count - windowSize)
        }

        if strongest == nil || rssi > strongest!.rssi {
            strongest = reading
        }
        if source != .pairedFallback {
            lastBLEReadingAt = reading.time
            fallbackNote = nil
        }
        feedClicker()
    }

    /// The value for the clicker: the same smoothed RSSI shown on screen, or
    /// nil if there has been no valid target reading for `soundSilenceAfter`
    /// seconds, so silence means "no current signal".
    private func soundSignal() -> Int? {
        guard let last = recent.last,
              Date().timeIntervalSince(last.time) <= soundSilenceAfter else { return nil }
        return smoothedRSSI()
    }

    private func feedClicker() {
        clicker?.update(rssi: soundSignal())
    }

    /// Median of the newest readings (up to 7). For an even count, the
    /// average of the two middle values.
    private func smoothedRSSI() -> Int? {
        guard !recent.isEmpty else { return nil }
        let sorted = recent.map(\.rssi).sorted()
        let middle = sorted.count / 2
        if sorted.count % 2 == 1 {
            return sorted[middle]
        }
        return Int((Double(sorted[middle - 1] + sorted[middle]) / 2).rounded())
    }

    // MARK: - Screen

    @objc private func tick() {
        checkConnectTimeout()
        // Also catches the 10-second silence when no new readings arrive.
        // The clicker keeps its own timing; this only updates its target value.
        feedClicker()
        draw()
    }

    private func draw() {
        let now = Date()
        var out = ""
        if isTerminal {
            out += "\u{1B}[H\u{1B}[2J"  // Move cursor to top-left and clear the screen.
        }

        out += "findphone - HUNT mode   (press Ctrl+C to quit)\n"
        out += "Target: \"\(targetName)\"  (you confirmed you own it with --owned)\n"
        if redact {
            out += "Privacy: --redact is on. Only the name you typed is shown.\n"
        }
        out += "Status: \(statusLine)\n"
        if let peripheral = target {
            out += "BLE identifier: \(redact ? "hidden" : peripheral.identifier.uuidString)\n"
        }
        out += "\n"

        if let value = smoothedRSSI() {
            out += BigDigits.render(String(value)) + "\n"
            out += "dBm   (median of the newest \(recent.count) of up to \(windowSize) readings)\n"
        } else {
            out += BigDigits.render("---") + "\n"
            out += "Waiting for the first signal reading...\n"
        }
        out += "\n"

        out += "Source:     \(recent.last?.source.rawValue ?? "none yet")\n"
        if let last = recent.last {
            let age = now.timeIntervalSince(last.time)
            let stale = age > 3 ? "   (no new readings - value may be out of date)" : ""
            out += "Latest:     \(last.rssi) dBm, \(String(format: "%.1f", age)) s ago\(stale)\n"
        }
        if let best = strongest {
            out += "Strongest:  \(best.rssi) dBm via \(best.source.rawValue), at \(clock(best.time.timeIntervalSince(startedAt))) into the hunt\n"
        } else {
            out += "Strongest:  none yet\n"
        }
        out += "Elapsed:    \(clock(now.timeIntervalSince(startedAt)))\n"
        if let clicker {
            if let interval = clicker.interval {
                out += "Sound:      on - one click every \(String(format: "%.2f", interval)) s\n"
            } else {
                out += "Sound:      on - silent (no target reading in the last \(Int(soundSilenceAfter)) s)\n"
            }
        }

        if let note = fallbackNote {
            out += "\n\(note)\n"
        }
        if recent.isEmpty {
            out += """

            Tip: the name must match exactly (only upper/lower case may differ).
            Copy it from survey mode or --list, and watch for ’ versus '.

            """
        }
        out += "\nCloser to 0 means nearer (about -40 is very close, -90 is far). Walk around and watch it rise.\n"

        print(out, terminator: "")
        fflush(stdout)
    }

    /// Formats seconds as mm:ss.
    private func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// Draws text such as "-57" as large ASCII-art digits, 5 lines tall.
enum BigDigits {
    private static let glyphs: [Character: [String]] = [
        "0": [" ### ", "#   #", "#   #", "#   #", " ### "],
        "1": ["  #  ", " ##  ", "  #  ", "  #  ", " ### "],
        "2": [" ### ", "#   #", "  ## ", " #   ", "#####"],
        "3": ["#### ", "    #", " ### ", "    #", "#### "],
        "4": ["#   #", "#   #", "#####", "    #", "    #"],
        "5": ["#####", "#    ", "#### ", "    #", "#### "],
        "6": [" ### ", "#    ", "#### ", "#   #", " ### "],
        "7": ["#####", "    #", "   # ", "  #  ", "  #  "],
        "8": [" ### ", "#   #", " ### ", "#   #", " ### "],
        "9": [" ### ", "#   #", " ####", "    #", " ### "],
        "-": ["     ", "     ", "#####", "     ", "     "],
    ]

    static func render(_ text: String) -> String {
        var lines = Array(repeating: "", count: 5)
        for character in text {
            let glyph = glyphs[character] ?? Array(repeating: "     ", count: 5)
            for row in 0..<5 {
                lines[row] += glyph[row] + "  "
            }
        }
        return lines.map { "    " + $0 }.joined(separator: "\n")
    }
}
