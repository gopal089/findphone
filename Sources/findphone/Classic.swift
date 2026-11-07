import Foundation

/// A Bluetooth device this Mac is already paired with, as reported by
/// System Information (`system_profiler`).
struct PairedDevice: Sendable {
    let name: String
    /// True if macOS says the device is connected to this Mac right now.
    let isConnected: Bool
    /// Signal strength macOS reported, if any. This can be the last value
    /// macOS remembers, so it may update slowly.
    let rssi: Int?
    /// macOS's description of the device type, such as "Headphones".
    let kind: String?
}

/// Reads macOS's list of paired Bluetooth devices.
///
/// This only *reads* what macOS already knows. It never scans, never
/// connects, and never starts pairing.
enum Classic {

    static let toolPath = "/usr/sbin/system_profiler"

    enum LookupError: Error, CustomStringConvertible {
        case couldNotStart(String)
        case failed(status: Int32)
        case unreadableOutput

        var description: String {
            switch self {
            case .couldNotStart(let reason): return "couldn't start \(Classic.toolPath): \(reason)"
            case .failed(let status): return "\(Classic.toolPath) exited with status \(status)"
            case .unreadableOutput: return "couldn't understand the output of \(Classic.toolPath)"
            }
        }
    }

    /// Runs `system_profiler SPBluetoothDataType -json` and returns the paired
    /// devices it lists. This takes a second or two, so hunt mode calls it on
    /// a background queue.
    static func pairedDevices() throws -> [PairedDevice] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: toolPath)
        process.arguments = ["SPBluetoothDataType", "-json"]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw LookupError.couldNotStart(error.localizedDescription)
        }
        // Read everything before waiting, so a large report can't fill the
        // pipe and stall the tool.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw LookupError.failed(status: process.terminationStatus)
        }
        return try parse(data)
    }

    /// Turns the JSON report into `PairedDevice` values.
    ///
    /// The report looks roughly like this (values shortened):
    ///
    ///     { "SPBluetoothDataType": [ {
    ///         "device_connected":     [ { "My Headphones": { "device_minorType": "Headphones", ... } } ],
    ///         "device_not_connected": [ { "My Phone": { "device_rssi": "-60", ... } } ]
    ///     } ] }
    ///
    /// Each device is a one-entry dictionary whose key is the device's name.
    static func parse(_ data: Data) throws -> [PairedDevice] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = root["SPBluetoothDataType"] as? [[String: Any]] else {
            throw LookupError.unreadableOutput
        }

        var devices: [PairedDevice] = []
        for section in sections {
            for (listKey, connected) in [("device_connected", true), ("device_not_connected", false)] {
                guard let entries = section[listKey] as? [[String: Any]] else { continue }
                for entry in entries {
                    for (rawName, value) in entry {
                        guard let name = cleanedName(rawName) else { continue }
                        let info = value as? [String: Any] ?? [:]
                        devices.append(PairedDevice(
                            name: name,
                            isConnected: connected,
                            rssi: number(from: info["device_rssi"]),
                            kind: info["device_minorType"] as? String
                        ))
                    }
                }
            }
        }
        return devices
    }

    /// The report stores numbers as text (for example "-60"); accept either.
    private static func number(from value: Any?) -> Int? {
        if let text = value as? String {
            return Int(text.trimmingCharacters(in: .whitespaces))
        }
        return (value as? NSNumber)?.intValue
    }

    // MARK: - --list mode

    /// Prints the paired devices so the learner can copy an exact name.
    /// With `redact`, every name prints as "Paired device". (Bluetooth
    /// addresses are never printed, redacted or not.)
    /// Returns the exit status for the program.
    static func runList(redact: Bool = false) -> Int32 {
        print("Reading this Mac's paired Bluetooth devices from System Information...")
        print("This only reads macOS's saved list. It does not scan, connect, or pair.")
        if redact {
            print("Privacy: --redact is on. Names are hidden; addresses are never shown.")
        }
        print("")

        let devices: [PairedDevice]
        do {
            devices = try pairedDevices()
        } catch {
            FileHandle.standardError.write(Data("findphone: couldn't read paired devices: \(error)\n".utf8))
            return 1
        }

        if devices.isEmpty {
            print("No paired Bluetooth devices found.")
            return 0
        }

        let nameWidth = 32
        let statusWidth = 15
        print(padded("NAME", nameWidth) + "  " + padded("STATUS", statusWidth) + "  " + padded("LAST RSSI", 10) + "  TYPE")
        print(String(repeating: "-", count: nameWidth + statusWidth + 10 + 6 + 12))

        // Alphabetical order would hint at the hidden names, so when
        // redacting, sort by connection status instead.
        let sorted = redact
            ? devices.sorted { $0.isConnected && !$1.isConnected }
            : devices.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        for device in sorted {
            let name = redact ? "Paired device" : device.name
            let status = device.isConnected ? "connected" : "not connected"
            let rssi = device.rssi.map { "\($0) dBm" } ?? "-"
            print(padded(name, nameWidth) + "  " + padded(status, statusWidth) + "  "
                  + padded(rssi, 10) + "  " + (device.kind ?? "-"))
        }

        if redact {
            print("""

            Names are hidden. To copy an exact name, run --list without --redact
            in your own Terminal, and don't share that unredacted output.
            """)
        } else {
            print("""

            To hunt for one of YOUR devices, copy its name exactly (watch for ’ versus ')
            and confirm you own it with --owned, for example:
              swift run findphone "Exact Device Name" --owned
            """)
        }
        return 0
    }
}
