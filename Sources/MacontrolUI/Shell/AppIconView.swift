import SwiftUI

/// The placeholder app icon: a sunburst on a blue-teal tile. Also rendered into AppIcon.icns
/// by `Macontrol --render-icon` (scripts/bundle-app.sh).
public struct AppIconView: View {
    public init() {}

    public var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                RoundedRectangle(cornerRadius: side * 0.225, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Color(red: 0.33, green: 0.40, blue: 0.98), Color(red: 0.10, green: 0.72, blue: 0.80)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                ring(radius: 0.36, width: 0.10, side: side, segments: [(0, 0.34, 0.9), (0.36, 0.52, 0.6), (0.62, 0.84, 0.45)])
                ring(radius: 0.245, width: 0.10, side: side, segments: [(0, 0.55, 1), (0.57, 0.83, 0.75), (0.85, 0.98, 0.55)])
                Circle().fill(.white).frame(width: side * 0.26, height: side * 0.26)
            }
            .frame(width: side, height: side)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private func ring(radius: Double, width: Double, side: CGFloat, segments: [(Double, Double, Double)]) -> some View {
        ZStack {
            ForEach(segments.indices, id: \.self) { index in
                let (from, to, opacity) = segments[index]
                Circle()
                    .trim(from: from, to: to)
                    .stroke(.white.opacity(opacity), style: StrokeStyle(lineWidth: side * width, lineCap: .butt))
            }
        }
        .rotationEffect(.degrees(-90))
        .frame(width: side * radius * 2, height: side * radius * 2)
    }
}
