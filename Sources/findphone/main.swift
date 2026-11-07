import Foundation

// findphone: entry point.
//
//   findphone                    Survey: list nearby BLE devices (listen only).
//   findphone --list             Show devices already paired with this Mac (read only).
//   findphone "NAME" --owned     Hunt: track one device you own, by its exact name.
//   add --sound to hunt mode     Click faster as the signal gets stronger.
//   add --redact to any mode     Hide device names, identifiers, and addresses.
//
// findphone never starts pairing. It connects only in hunt mode, only after
// --owned, and only to the device whose name matches exactly.

let usage = """
Usage:
  findphone                      Survey: list nearby Bluetooth LE devices (listen only).
  findphone --list               Show devices already paired with this Mac (read only).
  findphone "NAME" --owned       Hunt: track ONE device you own, by its exact name.
  findphone "NAME" --owned --sound
                                 Hunt with clicks that speed up as you get closer.
  Add --redact to any mode       Privacy: hide names, identifiers, and addresses.

--owned is your confirmation that the named device belongs to you.
--sound works in hunt mode only. Silence means there is no current signal.
--redact:  survey shows every device as "Nearby device" with identifier "hidden";
           --list shows every device as "Paired device";
           hunt shows only the name you typed, with its identifier "hidden".
           findphone never prints Bluetooth addresses. Use --redact before sharing output.
Names match exactly; only upper/lower case may differ. Put names with spaces in quotes.
findphone never pairs with any device.
"""

enum Mode {
    case survey
    case list
    case hunt(target: String, sound: Bool)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("findphone: \(message)\n\n\(usage)\n".utf8))
    exit(2)
}

/// Works out the mode (and whether to redact) from the command-line
/// arguments, or exits with an error.
func parseMode(_ arguments: [String]) -> (mode: Mode, redact: Bool) {
    var owned = false
    var list = false
    var sound = false
    var redact = false
    var names: [String] = []

    for argument in arguments {
        switch argument {
        case "--redact":
            redact = true
        case "--owned":
            owned = true
        case "--list":
            list = true
        case "--sound":
            sound = true
        case "--help", "-h":
            print(usage)
            exit(0)
        default:
            if argument.hasPrefix("-") {
                fail("unknown option \(argument)")
            }
            names.append(argument)
        }
    }

    if list {
        guard names.isEmpty, !owned, !sound else {
            fail("--list only reads the paired-device list; don't combine it with a name, --owned, or --sound.")
        }
        return (.list, redact)
    }

    if names.count > 1 {
        fail("give exactly one device name. If the name has spaces, put it in quotes.")
    }

    guard let name = names.first else {
        if owned {
            fail("--owned needs the exact name of the device you own.")
        }
        if sound {
            fail("--sound works in hunt mode only: findphone \"NAME\" --owned --sound")
        }
        return (.survey, redact)
    }

    guard !name.trimmingCharacters(in: .whitespaces).isEmpty else {
        fail("the device name is empty.")
    }

    // SAFETY CHECK: hunt mode connects to a device, so require confirmation.
    guard owned else {
        FileHandle.standardError.write(Data("""
        findphone: SAFETY ERROR - hunt mode not started.
        Hunt mode connects to a Bluetooth device, so findphone first needs your
        confirmation that you own "\(name)". Only track devices that belong to you.

        If "\(name)" is yours, run again with --owned:
          swift run findphone "\(name)" --owned

        """.utf8))
        exit(2)
    }

    return (.hunt(target: name, sound: sound), redact)
}

// `dropFirst()` skips the program's own path.
let (mode, redact) = parseMode(Array(CommandLine.arguments.dropFirst()))

switch mode {
case .survey:
    print("findphone: starting Bluetooth. The first time, macOS may ask you to allow Bluetooth access.")
    let finder = Finder(redact: redact)
    // CoreBluetooth delivers callbacks on the main queue. Running the main
    // RunLoop keeps the program (and `finder`) alive so they can fire.
    withExtendedLifetime(finder) {
        RunLoop.main.run()
    }

case .list:
    // Reads system_profiler output only; no Bluetooth scanning at all.
    exit(Classic.runList(redact: redact))

case .hunt(let target, let sound):
    var clicker: Clicker?
    if sound {
        // Silence is meant to say "no signal", so don't hunt quietly if the
        // sound can't load; stop and say so instead.
        guard let loaded = Clicker() else {
            FileHandle.standardError.write(Data("findphone: couldn't load \(Clicker.soundPath). Run without --sound.\n".utf8))
            exit(1)
        }
        clicker = loaded
    }
    print("findphone: starting hunt for \"\(target)\". macOS may ask you to allow Bluetooth access.")
    let hunter = Hunter(targetName: target, clicker: clicker, redact: redact)
    withExtendedLifetime(hunter) {
        RunLoop.main.run()
    }
}
