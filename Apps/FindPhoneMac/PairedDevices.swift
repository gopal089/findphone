import Foundation

/// Names of Bluetooth devices this Mac is paired with, read from System
/// Information (`system_profiler`). Read-only: it never scans, connects, or
/// pairs. Used to fill the "Paired devices" menu so you can pick an exact
/// name instead of typing it (including curly apostrophes like ’).
enum PairedDevices {

    static func loadNames(completion: @escaping ([String]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let names = (try? readNames()) ?? []
            DispatchQueue.main.async {
                completion(names)
            }
        }
    }

    private static func readNames() throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = root["SPBluetoothDataType"] as? [[String: Any]] else { return [] }

        // Each device is a one-entry dictionary whose key is its name.
        var names = Set<String>()
        for section in sections {
            for listKey in ["device_connected", "device_not_connected"] {
                for entry in section[listKey] as? [[String: Any]] ?? [] {
                    names.formUnion(entry.keys)
                }
            }
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}
