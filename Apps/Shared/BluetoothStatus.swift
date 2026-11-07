import CoreBluetooth

enum BluetoothStatus {
    /// A plain-English explanation of a Bluetooth state that prevents
    /// searching, or nil when Bluetooth is on and ready.
    static func problem(for state: CBManagerState) -> String? {
        switch state {
        case .poweredOn:
            return nil
        case .poweredOff:
            return "Bluetooth is off. Turn it on in Control Center; findphone will continue automatically."
        case .unauthorized:
            return "findphone isn't allowed to use Bluetooth. Turn it on in Settings > Privacy & Security > Bluetooth."
        case .unsupported:
            return "This device doesn't support Bluetooth Low Energy."
        case .resetting:
            return "Bluetooth is restarting. Waiting..."
        case .unknown:
            return "Checking Bluetooth..."
        @unknown default:
            return "Bluetooth is in an unexpected state. Waiting..."
        }
    }
}
