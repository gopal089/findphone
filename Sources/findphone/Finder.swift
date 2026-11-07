import Foundation
import CoreBluetooth

/// SURVEY MODE.
///
/// Listens for Bluetooth Low Energy (BLE) advertisements and shows a live,
/// refreshing table of nearby devices.
///
/// Finder only *listens*. It never connects to, pairs with, or sends anything
/// to any device, and it keeps nothing on disk.
final class Finder: NSObject, CBCentralManagerDelegate {

    /// What we remember about one device between screen refreshes.
    private struct Sighting {
        var name: String
        var rssi: Int
        var lastSeen: Date
    }

    /// The CoreBluetooth object that does the scanning. It is created in `init`
    /// because it needs `self` as its delegate.
    private var central: CBCentralManager!

    /// Latest sighting for each device, keyed by its CoreBluetooth identifier.
    /// (That identifier is a UUID macOS makes up for this Mac; it is not the
    /// device's hardware address.)
    private var sightings: [UUID: Sighting] = [:]

    /// Fires once per second to redraw the table.
    private var refreshTimer: Timer?

    /// Devices we haven't heard from in this many seconds drop off the list.
    private let staleAfter: TimeInterval = 30

    /// True when output goes to a real terminal window (not a file or pipe),
    /// so it's safe to use the "clear screen" escape code.
    private let isTerminal = isatty(STDOUT_FILENO) != 0

    /// With --redact, every name prints as "Nearby device" and every
    /// identifier as "hidden".
    private let redact: Bool

    private let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    init(redact: Bool = false) {
        self.redact = redact
        super.init()
        // `queue: nil` means CoreBluetooth calls our delegate methods on the
        // main queue, which the main RunLoop in main.swift keeps running.
        central = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: - CBCentralManagerDelegate

    /// Called when Bluetooth's state changes (and once right after startup).
    /// We may only scan while the state is `.poweredOn`.
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard let problem = bluetoothProblem(for: central.state) else {
            startScanning()
            return
        }
        stopRefreshing()
        print("\n" + problem.message)
        if problem.isFatal {
            exit(1)
        }
    }

    /// Called every time an advertisement is heard. Because we scan with
    /// "allow duplicates", this fires repeatedly for the same device, which
    /// keeps its RSSI (signal strength) up to date.
    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let rssi = RSSI.intValue
        // CoreBluetooth reports 127 when it has no real signal reading.
        guard rssi != 127 else { return }

        let id = peripheral.identifier

        // Name priority: the name in this advertisement, then the name
        // CoreBluetooth already knows, then a name we saw earlier (not every
        // advertisement packet includes one), then a placeholder.
        let name = cleanedName(advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? cleanedName(peripheral.name)
            ?? sightings[id]?.name
            ?? "Unnamed device"

        sightings[id] = Sighting(name: name, rssi: rssi, lastSeen: Date())
    }

    // MARK: - Scanning

    private func startScanning() {
        // `withServices: nil` asks for every advertising device.
        // AllowDuplicates reports each new advertisement instead of only the
        // first one, so RSSI keeps changing as you move around.
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )

        guard refreshTimer == nil else { return }
        refreshTimer = Timer.scheduledTimer(
            timeInterval: 1.0,
            target: self,
            selector: #selector(redraw),
            userInfo: nil,
            repeats: true
        )
        redraw()
    }

    /// Stops redrawing and forgets old sightings. macOS stops the scan by
    /// itself whenever Bluetooth leaves the powered-on state.
    private func stopRefreshing() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        sightings.removeAll()
    }

    // MARK: - Drawing the table

    private let nameWidth = 28
    private let idWidth = 36
    private let rssiWidth = 9

    @objc private func redraw() {
        let now = Date()

        // Drop devices we haven't heard from recently.
        sightings = sightings.filter { now.timeIntervalSince($0.value.lastSeen) <= staleAfter }

        // Strongest signal (usually closest) first.
        let rows = sightings.sorted { $0.value.rssi > $1.value.rssi }

        var out = ""
        if isTerminal {
            out += "\u{1B}[H\u{1B}[2J"  // Move cursor to top-left and clear the screen.
        }
        out += "findphone - live Bluetooth LE survey   (press Ctrl+C to quit)\n"
        out += "Listening only: findphone does not connect to or pair with any device.\n"
        if redact {
            out += "Privacy: --redact is on. Names and identifiers are hidden.\n"
        }
        out += "Devices: \(rows.count)   Updated: \(clockFormatter.string(from: now))\n\n"

        out += padded("NAME", nameWidth) + "  " + padded("IDENTIFIER", idWidth) + "  "
            + padded("RSSI", rssiWidth) + "  LAST SEEN\n"
        out += String(repeating: "-", count: nameWidth + idWidth + rssiWidth + 6 + 9) + "\n"

        if rows.isEmpty {
            out += "(no devices heard yet - keep waiting)\n"
        }
        for (id, sighting) in rows {
            let age = Int(now.timeIntervalSince(sighting.lastSeen))
            let name = redact ? "Nearby device" : sighting.name
            let identifier = redact ? "hidden" : id.uuidString
            out += padded(name, nameWidth) + "  "
                + padded(identifier, idWidth) + "  "
                + padded("\(sighting.rssi) dBm", rssiWidth) + "  "
                + "\(age)s ago\n"
        }

        out += "\nRSSI closer to 0 (for example -45) usually means nearer; around -90 means far away.\n"

        print(out, terminator: "")
        fflush(stdout)
    }
}

// MARK: - Helpers shared by survey, hunt, and --list

/// Explains a Bluetooth state that prevents scanning. Returns `nil` when
/// Bluetooth is powered on and ready. `isFatal` means waiting won't help,
/// so the program should exit.
func bluetoothProblem(for state: CBManagerState) -> (message: String, isFatal: Bool)? {
    switch state {
    case .poweredOn:
        return nil
    case .poweredOff:
        return ("""
        Bluetooth is turned off.
        Turn it on in Control Center or System Settings > Bluetooth.
        findphone will continue automatically when it's back on.
        """, false)
    case .unauthorized:
        if CBManager.authorization == .restricted {
            return ("Bluetooth access is restricted on this Mac (for example by a management profile), so findphone can't use Bluetooth.", true)
        }
        return ("""
        findphone doesn't have permission to use Bluetooth.
        Open System Settings > Privacy & Security > Bluetooth and turn on
        the app you ran findphone from (for example Terminal), then run findphone again.
        """, true)
    case .unsupported:
        return ("This Mac doesn't support Bluetooth Low Energy, so findphone can't use Bluetooth.", true)
    case .resetting:
        return ("Bluetooth is restarting. Waiting for it to come back...", false)
    case .unknown:
        return ("Checking Bluetooth status...", false)
    @unknown default:
        return ("Bluetooth reported an unexpected state (\(state.rawValue)). Waiting...", false)
    }
}

/// True when two device names are identical apart from upper/lower case.
/// "gopal’s iphone" matches "Gopal’s iPhone", but "Gopal's iPhone" (straight
/// apostrophe) does not, and neither does a partial name like "iPhone".
func namesMatch(_ a: String, _ b: String) -> Bool {
    a.caseInsensitiveCompare(b) == .orderedSame
}

/// Removes control characters (so a device name can't mess up the
/// terminal), trims spaces, and treats an empty result as "no name".
func cleanedName(_ raw: String?) -> String? {
    guard let raw else { return nil }
    var scalars = String.UnicodeScalarView()
    scalars.append(contentsOf: raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
    let trimmed = String(scalars).trimmingCharacters(in: .whitespaces)
    return trimmed.isEmpty ? nil : trimmed
}

/// Pads `text` with spaces to exactly `width` characters, shortening it
/// with "…" if it's too long, so table columns line up.
func padded(_ text: String, _ width: Int) -> String {
    if text.count > width {
        return String(text.prefix(width - 1)) + "…"
    }
    return text + String(repeating: " ", count: width - text.count)
}
