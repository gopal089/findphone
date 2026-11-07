import Foundation
import CoreBluetooth

/// What to search for.
enum HuntTarget: Equatable {
    /// A device whose Bluetooth name matches exactly (upper/lower case may differ).
    case named(String)
    /// A Mac running findphone with its beacon switched on.
    case findphoneBeacon

    var displayName: String {
        switch self {
        case .named(let name): return "\"\(name)\""
        case .findphoneBeacon: return "your Mac"
        }
    }
}

/// Searches for ONE device the user has confirmed they own and keeps track
/// of its signal strength (RSSI).
///
/// It makes a plain Bluetooth connection to that device only, so it can read
/// RSSI every 0.3 s. It never discovers services or reads data from the
/// device, which is what could make a device ask to pair. It never pairs.
final class HuntEngine: NSObject, ObservableObject {

    enum Source: String {
        case advertisement = "Advertisement"
        case connectedLink = "Connected link"
    }

    struct Reading {
        let rssi: Int
        let source: Source
        let time: Date
    }

    // MARK: Published state (the window shows these)

    @Published private(set) var target: HuntTarget?
    @Published private(set) var status = "Not searching."
    @Published private(set) var latest: Reading?
    @Published private(set) var strongest: Reading?
    @Published private(set) var startedAt: Date?
    @Published private(set) var endedAt: Date?
    @Published private(set) var isConnected = false
    /// The smoothed (median) RSSI, or nil when there has been no valid
    /// reading for `SignalMath.silenceAfter` seconds.
    @Published private(set) var currentSignal: Int?
    /// Every valid reading from the last minute, oldest first. Used for the
    /// closer/farther trend and the direction sweep.
    @Published private(set) var history: [Reading] = []

    var isHunting: Bool { target != nil }

    /// Called about three times a second with `currentSignal`, for sound.
    var onSignalUpdate: ((Int?) -> Void)?

    // MARK: Settings

    private let rssiInterval: TimeInterval = 0.3
    private let tickInterval: TimeInterval = 0.33
    private let connectTimeout: TimeInterval = 10

    // MARK: Private state

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var connectStartedAt: Date?
    private var recent: [Reading] = []
    private var smoothedRSSI: Int?
    private var rssiTimer: Timer?
    private var tickTimer: Timer?

    // MARK: - Start and stop

    /// Starts a search. `ownershipConfirmed` must be true: findphone only
    /// tracks devices the user has said they own.
    func start(_ newTarget: HuntTarget, ownershipConfirmed: Bool) {
        guard ownershipConfirmed else {
            status = "Safety check: confirm that this device is yours first."
            return
        }
        if case .named(let name) = newTarget, name.trimmingCharacters(in: .whitespaces).isEmpty {
            status = "Enter the exact name of your device first."
            return
        }

        stop()
        target = newTarget
        recent.removeAll()
        history.removeAll()
        smoothedRSSI = nil
        latest = nil
        strongest = nil
        currentSignal = nil
        startedAt = Date()
        endedAt = nil
        status = "Starting Bluetooth..."

        tickTimer = Timer.scheduledTimer(timeInterval: tickInterval, target: self,
                                         selector: #selector(tick), userInfo: nil, repeats: true)

        if let central {
            centralManagerDidUpdateState(central)
        } else {
            // Created on the first search, so macOS/iOS only asks for
            // Bluetooth permission when you actually start searching.
            central = CBCentralManager(delegate: self, queue: nil)
        }
    }

    /// Stops searching and drops the connection. The last results stay on
    /// screen until the next search.
    func stop() {
        guard target != nil else { return }
        tickTimer?.invalidate()
        tickTimer = nil
        if let central, central.state == .poweredOn {
            central.stopScan()
        }
        dropPeripheral()
        target = nil
        endedAt = Date()
        currentSignal = nil
        status = "Stopped."
        onSignalUpdate?(nil)
    }

    // MARK: - Readings

    private func record(_ rssi: Int, _ source: Source) {
        guard SignalMath.validRSSI.contains(rssi) else { return }
        let reading = Reading(rssi: rssi, source: source, time: Date())

        // Don't mix sources in one median: they're measured differently.
        if let last = recent.last, last.source != source {
            recent.removeAll()
        }
        recent.append(reading)
        if recent.count > SignalMath.windowSize {
            recent.removeFirst(recent.count - SignalMath.windowSize)
        }

        history.append(reading)
        history.removeAll { reading.time.timeIntervalSince($0.time) > 60 }

        smoothedRSSI = SignalMath.median(of: recent.map(\.rssi))
        latest = reading
        currentSignal = smoothedRSSI
        if strongest.map({ rssi > $0.rssi }) ?? true {
            strongest = reading
        }
    }

    @objc private func tick() {
        if let started = connectStartedAt, Date().timeIntervalSince(started) > connectTimeout {
            dropPeripheral()
            status = "Connection attempt timed out. Still listening for it..."
        }
        let isFresh = latest.map { Date().timeIntervalSince($0.time) <= SignalMath.silenceAfter } ?? false
        let signal = isFresh ? smoothedRSSI : nil
        if signal != currentSignal {
            currentSignal = signal
        }
        onSignalUpdate?(signal)
    }

    // MARK: - Helpers

    private func scan(for target: HuntTarget) {
        guard let central, central.state == .poweredOn else { return }
        // A beacon search only listens for findphone's own service.
        let services: [CBUUID]? = (target == .findphoneBeacon) ? [BeaconID.service] : nil
        central.scanForPeripherals(withServices: services,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        status = "Searching for \(target.displayName)..."
    }

    private func matches(_ target: HuntTarget, _ peripheral: CBPeripheral,
                         _ advertisementData: [String: Any]) -> Bool {
        switch target {
        case .named(let wanted):
            let names = [advertisementData[CBAdvertisementDataLocalNameKey] as? String, peripheral.name]
            return names.contains { name in name.map { SignalMath.namesMatch($0, wanted) } ?? false }
        case .findphoneBeacon:
            let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
            let overflow = advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? []
            return (services + overflow).contains(BeaconID.service)
        }
    }

    private func dropPeripheral() {
        rssiTimer?.invalidate()
        rssiTimer = nil
        if let peripheral, let central, central.state == .poweredOn, peripheral.state != .disconnected {
            central.cancelPeripheralConnection(peripheral)
        }
        peripheral = nil
        connectStartedAt = nil
        isConnected = false
    }
}

// MARK: - CoreBluetooth callbacks (delivered on the main queue)

extension HuntEngine: CBCentralManagerDelegate, CBPeripheralDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard let target else { return }
        if let problem = BluetoothStatus.problem(for: central.state) {
            dropPeripheral()
            status = problem
            return
        }
        scan(for: target)
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        guard let target, matches(target, peripheral, advertisementData) else { return }
        // Once one device is chosen, ignore any other with the same name.
        if let current = self.peripheral, current.identifier != peripheral.identifier { return }

        record(RSSI.intValue, .advertisement)

        if self.peripheral == nil {
            self.peripheral = peripheral
            peripheral.delegate = self
            connectStartedAt = Date()
            status = "Found it. Connecting (link only, no pairing)..."
            central.connect(peripheral, options: nil)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral.identifier == self.peripheral?.identifier else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        connectStartedAt = nil
        isConnected = true
        central.stopScan()
        status = "Connected (link only, not paired)."
        rssiTimer?.invalidate()
        rssiTimer = Timer.scheduledTimer(timeInterval: rssiInterval, target: self,
                                         selector: #selector(requestRSSI), userInfo: nil, repeats: true)
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        guard peripheral.identifier == self.peripheral?.identifier, let target else { return }
        dropPeripheral()
        status = "Couldn't connect. Still listening for it..."
        scan(for: target)
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        guard peripheral.identifier == self.peripheral?.identifier, let target else { return }
        dropPeripheral()
        scan(for: target)
        status = "Connection lost. Searching again..."
    }

    @objc private func requestRSSI() {
        guard let peripheral, peripheral.state == .connected else { return }
        peripheral.readRSSI()
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard error == nil else { return }
        record(RSSI.intValue, .connectedLink)
    }
}
