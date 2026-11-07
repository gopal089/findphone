import CoreBluetooth

/// Identifies the Bluetooth "beacon" a findphone Mac sends out when its
/// beacon switch is on, so the findphone iPhone app can find that Mac.
enum BeaconID {
    /// A made-up service UUID that only findphone uses.
    static let service = CBUUID(string: "6E0F2C1B-4D3A-4B8E-9C71-5A2D8F3E4B10")

    /// A generic advertised name. It deliberately does not include your
    /// name or the Mac's name.
    static let localName = "findphone"
}
