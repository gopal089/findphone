import SwiftUI

/// A 3D-style direction arrow standing on a tilted "floor" disc.
///
/// `rotation` is in degrees clockwise from straight ahead:
/// 0 = ahead, 90 = right, 180 = behind, 270 = left.
///
/// The 3D look comes from tilting the arrow and disc back in perspective,
/// then stacking several darker copies underneath the top face to give the
/// arrow visible thickness.
struct DirectionArrow3D: View {
    var rotation: Double
    var color: Color
    /// Active arrows glow and gently bob; inactive ones sit still and dim.
    var isActive: Bool = true

    private let tilt = 58.0          // how far the floor leans back
    private let perspective = 0.55
    private let layers = 9           // extrusion depth, in stacked copies
    private let layerStep: CGFloat = 1.7

    @State private var bob = false

    var body: some View {
        GeometryReader { geo in
            let disc = min(geo.size.width, geo.size.height * 1.5)
            ZStack {
                // Soft shadow on the "floor"
                Ellipse()
                    .fill(Color.black.opacity(0.28))
                    .frame(width: disc * 0.55, height: disc * 0.2)
                    .blur(radius: 10)
                    .offset(y: disc * 0.06)

                floor(disc)
                    .rotation3DEffect(.degrees(tilt), axis: (x: 1, y: 0, z: 0), perspective: perspective)

                // Drawn upright (not on the tilted floor) so it stays readable.
                Text("AHEAD")
                    .font(.system(size: disc * 0.065, weight: .heavy, design: .rounded))
                    .tracking(1.5)
                    .foregroundStyle(color.opacity(0.9))
                    .offset(y: -disc * 0.36)

                // Extruded arrow: darker layers first, bright top face last.
                ZStack {
                    ForEach(0..<layers, id: \.self) { index in
                        layer(index, disc: disc)
                            .rotationEffect(.degrees(rotation))
                            .rotation3DEffect(.degrees(tilt), axis: (x: 1, y: 0, z: 0), perspective: perspective)
                            .offset(y: -CGFloat(index) * layerStep)
                    }
                }
                .offset(y: (bob && isActive) ? -disc * 0.035 : 0)
                .shadow(color: color.opacity(isActive ? 0.65 : 0), radius: 14)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .opacity(isActive ? 1 : 0.55)
        }
        .animation(.spring(response: 0.7, dampingFraction: 0.6), value: rotation)
        .animation(.easeInOut(duration: 0.4), value: isActive)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                bob = true
            }
        }
        .accessibilityHidden(true)
    }

    /// One slice of the arrow. The top slice gets a highlight; lower slices
    /// are darker, which reads as the arrow's side wall.
    @ViewBuilder
    private func layer(_ index: Int, disc: CGFloat) -> some View {
        let isTop = index == layers - 1
        let size = CGSize(width: disc * 0.34, height: disc * 0.5)
        if isTop {
            ArrowShape()
                .fill(color)
                .overlay(ArrowShape().fill(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.0)],
                                                          startPoint: .top, endPoint: .bottom)))
                .overlay(ArrowShape().stroke(Color.white.opacity(0.7), lineWidth: 1.2))
                .frame(width: size.width, height: size.height)
        } else {
            ArrowShape()
                .fill(color)
                .brightness(-0.42 + Double(index) * 0.025)
                .frame(width: size.width, height: size.height)
        }
    }

    /// The disc the arrow stands on, with marks for ahead/right/behind/left.
    private func floor(_ disc: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [color.opacity(0.3), color.opacity(0.03)],
                                     center: .center, startRadius: 0, endRadius: disc / 2))
            Circle()
                .stroke(color.opacity(0.6), lineWidth: 3)
            Circle()
                .stroke(color.opacity(0.3), style: StrokeStyle(lineWidth: 1.5, dash: [4, 6]))
                .padding(disc * 0.17)
            ForEach(0..<4, id: \.self) { quarter in
                Capsule()
                    .fill(color.opacity(quarter == 0 ? 0.95 : 0.5))
                    .frame(width: quarter == 0 ? 5 : 3, height: disc * 0.08)
                    .offset(y: -disc / 2 + disc * 0.06)
                    .rotationEffect(.degrees(Double(quarter) * 90))
            }
        }
        .frame(width: disc, height: disc)
    }
}

/// A classic arrow pointing up, filling its frame.
struct ArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let shoulder = rect.minY + h * 0.45
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))                   // tip
        path.addLine(to: CGPoint(x: rect.maxX, y: shoulder))                 // right wing
        path.addLine(to: CGPoint(x: rect.minX + w * 0.67, y: shoulder))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.67, y: rect.maxY))     // shaft
        path.addLine(to: CGPoint(x: rect.minX + w * 0.33, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.33, y: shoulder))
        path.addLine(to: CGPoint(x: rect.minX, y: shoulder))                 // left wing
        path.closeSubpath()
        return path
    }
}
