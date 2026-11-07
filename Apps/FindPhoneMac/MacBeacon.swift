import Foundation
import CoreBluetooth

/// Makes this Mac findable by the findphone iPhone app.
///
/// While switched on, the Mac advertises findphone's own Bluetooth service
/// with the generic name "findphone". The iPhone app can then connect (link
/// only, no pairing) and read the signal strength. There is nothing to read
/// or write on this service, so a connection can't trigger pairing.
///
/// Off by default: anyone nearby with a Bluetooth scanner could see that a
/// findphone beacon exists while it's on.
final class MacBeacon: NSObject, ObservableObject, CBPeripheralManagerDelegate {

    @Published private(set) var isOn = false
    @Published private(set) var status = "Off."

    private var manager: CBPeripheralManager?
    private var serviceAdded = false

    func setOn(_ on: Bool) {
        isOn = on
        if on {
            status = "Starting..."
            if let manager {
                peripheralManagerDidUpdateState(manager)
            } else {
                // Created on first use, so Bluetooth permission is only
                // requested when you turn the beacon on.
                manager = CBPeripheralManager(delegate: self, queue: nil)
            }
        } else {
            manager?.stopAdvertising()
            status = "Off."
        }
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard isOn else { return }
        if let problem = BluetoothStatus.problem(for: peripheral.state) {
            status = problem
            return
        }
        if serviceAdded {
            advertise()
        } else {
            peripheral.add(CBMutableService(type: BeaconID.service, primary: true))
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error {
            status = "Couldn't start the beacon: \(error.localizedDescription)"
            return
        }
        serviceAdded = true
        if isOn {
            advertise()
        }
    }

    private func advertise() {
        guard let manager, !manager.isAdvertising else { return }
        manager.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [BeaconID.service],
            CBAdvertisementDataLocalNameKey: BeaconID.localName,
        ])
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error {
            status = "Couldn't start the beacon: \(error.localizedDescription)"
            return
        }
        status = isOn ? "On. Your iPhone can find this Mac while it's awake and in range." : "Off."
        if !isOn {
            peripheral.stopAdvertising()
        }
    }
}
