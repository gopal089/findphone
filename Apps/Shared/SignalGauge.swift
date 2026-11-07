import SwiftUI

/// A digital speedometer for signal strength: a dashboard dial from
/// -100 dBm (far) to -30 dBm (very close), a springy needle, a marker for
/// the strongest reading so far, and a glowing seven-segment readout.
struct SignalGauge: View {
    /// Smoothed RSSI to show, or nil when there's no current signal.
    let rssi: Int?
    /// Strongest reading so far (shown as a white dot on the arc).
    let strongest: Int?

    static let minDBm = -100.0
    static let maxDBm = -30.0

    /// The dial runs clockwise from bottom-left (135°) to bottom-right (405°).
    private let startDegrees = 135.0
    private let sweepDegrees = 270.0

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            dial(side: side)
                .frame(width: side, height: side)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rssi.map { "Signal \($0) dBm, \(Self.zone($0).label)" } ?? "No signal")
    }

    // MARK: - Zones

    /// A word and colour for how close the signal suggests you are.
    static func zone(_ rssi: Int?) -> (label: String, color: Color) {
        guard let rssi else { return ("NO SIGNAL", .gray) }
        if rssi >= -45 { return ("VERY CLOSE", .green) }
        if rssi >= -60 { return ("CLOSE", Color(red: 0.55, green: 0.9, blue: 0.2)) }
        if rssi >= -75 { return ("NEARBY", .yellow) }
        if rssi >= -90 { return ("FAR", .orange) }
        return ("VERY FAR", .red)
    }

    // MARK: - Geometry

    private func fraction(_ value: Double) -> Double {
        min(max((value - Self.minDBm) / (Self.maxDBm - Self.minDBm), 0), 1)
    }

    /// Angle on the dial for a dBm value (SwiftUI angles: 0° = 3 o'clock, clockwise).
    private func degrees(_ value: Double) -> Double {
        startDegrees + fraction(value) * sweepDegrees
    }

    // MARK: - Drawing

    private func dial(side: CGFloat) -> some View {
        let zone = Self.zone(rssi)
        let value = Double(rssi ?? Int(Self.minDBm))
        let trackInset = side * 0.10
        let trackWidth = side * 0.055
        let trackRadius = side / 2 - trackInset
        let arc = sweepDegrees / 360
        let colors = AngularGradient(
            gradient: Gradient(colors: [.red, .orange, .yellow, Color(red: 0.55, green: 0.9, blue: 0.2), .green]),
            center: .center,
            startAngle: .degrees(0),
            endAngle: .degrees(sweepDegrees)
        )

        return ZStack {
            // Dial face and bezel
            Circle()
                .fill(RadialGradient(colors: [Color(white: 0.22), Color(white: 0.04)],
                                     center: .center, startRadius: 0, endRadius: side / 2))
            Circle()
                .strokeBorder(LinearGradient(colors: [Color(white: 0.6), Color(white: 0.1)],
                                             startPoint: .top, endPoint: .bottom),
                              lineWidth: side * 0.022)

            // Dim full track
            Circle()
                .trim(from: 0, to: arc)
                .stroke(colors, style: StrokeStyle(lineWidth: trackWidth, lineCap: .round))
                .rotationEffect(.degrees(startDegrees))
                .padding(trackInset)
                .opacity(0.2)

            // Lit track up to the current value
            Circle()
                .trim(from: 0, to: rssi == nil ? 0 : arc * fraction(value))
                .stroke(colors, style: StrokeStyle(lineWidth: trackWidth, lineCap: .round))
                .rotationEffect(.degrees(startDegrees))
                .padding(trackInset)
                .shadow(color: zone.color.opacity(0.8), radius: side * 0.03)

            ticks(side: side)

            // Strongest-so-far marker
            if let strongest {
                let radians = degrees(Double(strongest)) * .pi / 180
                Circle()
                    .fill(Color.white)
                    .frame(width: side * 0.032, height: side * 0.032)
                    .shadow(color: .white, radius: 4)
                    .offset(x: cos(radians) * trackRadius, y: sin(radians) * trackRadius)
            }

            readout(side: side, zone: zone)

            // Needle (drawn pointing up, then rotated to the value)
            Capsule()
                .fill(LinearGradient(colors: [Color(red: 1, green: 0.25, blue: 0.15), .orange],
                                     startPoint: .bottom, endPoint: .top))
                .frame(width: side * 0.024, height: side * 0.37)
                .offset(y: -side * 0.17)
                .rotationEffect(.degrees(degrees(value) + 90))
                .shadow(color: .red.opacity(0.7), radius: 5)
                .opacity(rssi == nil ? 0.35 : 1)

            // Hub
            Circle()
                .fill(RadialGradient(colors: [Color(white: 0.75), Color(white: 0.2)],
                                     center: .topLeading, startRadius: 0, endRadius: side * 0.06))
                .frame(width: side * 0.09, height: side * 0.09)
                .overlay(Circle().stroke(Color.black.opacity(0.6), lineWidth: 1))

            // Zone label in the open gap at the bottom of the dial
            Text(zone.label)
                .font(.system(size: side * 0.045, weight: .heavy, design: .rounded))
                .tracking(2)
                .foregroundStyle(zone.color)
                .shadow(color: zone.color.opacity(0.8), radius: 4)
                .offset(y: side * 0.425)
        }
        .animation(.spring(response: 0.6, dampingFraction: 0.62), value: rssi)
        .animation(.easeOut(duration: 0.4), value: strongest)
    }

    /// Tick marks every 2 dB, with a label every 10 dB.
    private func ticks(side: CGFloat) -> some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let outer = side / 2 - side * 0.17
            for value in stride(from: Self.minDBm, through: Self.maxDBm, by: 2) {
                let isMajor = Int(value) % 10 == 0
                let radians = degrees(value) * .pi / 180
                let length = isMajor ? side * 0.055 : side * 0.028
                var path = Path()
                path.move(to: CGPoint(x: center.x + cos(radians) * outer,
                                      y: center.y + sin(radians) * outer))
                path.addLine(to: CGPoint(x: center.x + cos(radians) * (outer - length),
                                         y: center.y + sin(radians) * (outer - length)))
                context.stroke(path,
                               with: .color(.white.opacity(isMajor ? 0.9 : 0.35)),
                               lineWidth: isMajor ? 2 : 1)
                if isMajor {
                    let labelRadius = outer - length - side * 0.055
                    let label = Text("\(Int(value))")
                        .font(.system(size: side * 0.042, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.8))
                    context.draw(label, at: CGPoint(x: center.x + cos(radians) * labelRadius,
                                                    y: center.y + sin(radians) * labelRadius))
                }
            }
        }
    }

    /// The number, right-aligned in four cells, drawn as glowing seven-segment
    /// LCD digits (unlit segments show as faint ghosts).
    private var readoutText: String {
        let text = rssi.map { String($0) } ?? "--"
        return String(repeating: " ", count: max(0, 4 - text.count)) + text
    }

    private func readout(side: CGFloat, zone: (label: String, color: Color)) -> some View {
        VStack(spacing: side * 0.012) {
            LCDText(text: readoutText, height: side * 0.1, ink: zone.color)
                .shadow(color: zone.color.opacity(0.9), radius: side * 0.018)

            Text("dBm")
                .font(.system(size: side * 0.038, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
        }
        .padding(.horizontal, side * 0.035)
        .padding(.vertical, side * 0.02)
        .background(
            RoundedRectangle(cornerRadius: side * 0.03)
                .fill(Color.black.opacity(0.8))
                .overlay(RoundedRectangle(cornerRadius: side * 0.03)
                    .stroke(Color.white.opacity(0.15), lineWidth: 1))
        )
        // Low enough to clear the -100 and -30 labels at the ends of the dial.
        .offset(y: side * 0.27)
    }
}
