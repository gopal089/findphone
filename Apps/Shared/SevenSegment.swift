import SwiftUI

// SEVEN-SEGMENT LCD DIGITS
//
// Each digit is drawn from seven bars, like a real LCD:
//
//        a
//      f   b
//        g
//      e   c
//        d
//
// Unlit bars are drawn very faintly, the way you can see the "ghost"
// segments on a real dashboard display.

enum Segment: CaseIterable {
    case a, b, c, d, e, f, g

    /// Which bars are lit for a character. Unknown characters are blank.
    static func lit(for character: Character) -> Set<Segment> {
        switch character {
        case "0": return [.a, .b, .c, .d, .e, .f]
        case "1": return [.b, .c]
        case "2": return [.a, .b, .g, .e, .d]
        case "3": return [.a, .b, .g, .c, .d]
        case "4": return [.f, .g, .b, .c]
        case "5": return [.a, .f, .g, .c, .d]
        case "6": return [.a, .f, .g, .e, .c, .d]
        case "7": return [.a, .b, .c]
        case "8": return Set(Segment.allCases)
        case "9": return [.a, .b, .c, .d, .f, .g]
        case "-": return [.g]
        default: return []
        }
    }
}

/// The outline of the chosen bars, leaning forward like an italic LCD.
struct SevenSegmentShape: Shape {
    var segments: Set<Segment>
    /// Forward lean, as a fraction of the height.
    var slant: CGFloat = LCDText.slant

    func path(in rect: CGRect) -> Path {
        let h = rect.height
        let w = rect.width - slant * h          // room for the lean
        let t = w * 0.2                         // bar thickness
        let gap = t * 0.16                      // small gap where bars meet
        let left = t / 2, right = w - t / 2
        let top = t / 2, mid = h / 2, bottom = h - t / 2

        var path = Path()

        // A flat hexagon lying sideways.
        func horizontal(_ y: CGFloat) {
            let x0 = left + gap, x1 = right - gap
            path.move(to: CGPoint(x: x0, y: y))
            path.addLine(to: CGPoint(x: x0 + t / 2, y: y - t / 2))
            path.addLine(to: CGPoint(x: x1 - t / 2, y: y - t / 2))
            path.addLine(to: CGPoint(x: x1, y: y))
            path.addLine(to: CGPoint(x: x1 - t / 2, y: y + t / 2))
            path.addLine(to: CGPoint(x: x0 + t / 2, y: y + t / 2))
            path.closeSubpath()
        }

        // A flat hexagon standing up.
        func vertical(_ x: CGFloat, from y0: CGFloat, to y1: CGFloat) {
            let a = y0 + gap, b = y1 - gap
            path.move(to: CGPoint(x: x, y: a))
            path.addLine(to: CGPoint(x: x + t / 2, y: a + t / 2))
            path.addLine(to: CGPoint(x: x + t / 2, y: b - t / 2))
            path.addLine(to: CGPoint(x: x, y: b))
            path.addLine(to: CGPoint(x: x - t / 2, y: b - t / 2))
            path.addLine(to: CGPoint(x: x - t / 2, y: a + t / 2))
            path.closeSubpath()
        }

        for segment in segments {
            switch segment {
            case .a: horizontal(top)
            case .g: horizontal(mid)
            case .d: horizontal(bottom)
            case .f: vertical(left, from: top, to: mid)
            case .b: vertical(right, from: top, to: mid)
            case .e: vertical(left, from: mid, to: bottom)
            case .c: vertical(right, from: mid, to: bottom)
            }
        }

        // Lean forward: the top moves right, the bottom stays put.
        let lean = CGAffineTransform(a: 1, b: 0, c: -slant, d: 1, tx: slant * h, ty: 0)
        return path.applying(lean).offsetBy(dx: rect.minX, dy: rect.minY)
    }
}

/// A row of LCD characters. Supports 0-9, "-", ":", "." and spaces.
struct LCDText: View {
    let text: String
    let height: CGFloat
    var ink: Color = LCDPalette.ink

    static let slant: CGFloat = 0.12
    static let ghostOpacity = 0.08

    private var digitWidth: CGFloat { height * 0.56 + LCDText.slant * height }

    var body: some View {
        HStack(spacing: height * 0.09) {
            ForEach(Array(text.enumerated()), id: \.offset) { _, character in
                cell(character)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text.trimmingCharacters(in: .whitespaces))
    }

    @ViewBuilder
    private func cell(_ character: Character) -> some View {
        switch character {
        case ":":
            VStack(spacing: height * 0.26) {
                dot
                dot
            }
            .frame(width: height * 0.22, height: height)
        case ".":
            dot
                .frame(width: height * 0.22, height: height, alignment: .bottom)
        default:
            ZStack {
                SevenSegmentShape(segments: Set(Segment.allCases))
                    .fill(ink.opacity(LCDText.ghostOpacity))
                SevenSegmentShape(segments: Segment.lit(for: character))
                    .fill(ink)
            }
            .frame(width: digitWidth, height: height)
        }
    }

    private var dot: some View {
        Rectangle()
            .fill(ink)
            .frame(width: height * 0.13, height: height * 0.13)
    }
}

/// Colours of a classic grey-green LCD.
enum LCDPalette {
    static let ink = Color(red: 0.07, green: 0.08, blue: 0.07)
    static let glassTop = Color(red: 0.84, green: 0.87, blue: 0.80)
    static let glassBottom = Color(red: 0.71, green: 0.75, blue: 0.67)
    static let frame = Color(white: 0.33)
}
