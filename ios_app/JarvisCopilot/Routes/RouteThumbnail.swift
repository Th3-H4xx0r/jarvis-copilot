import SwiftUI

/// A route's outline, from the summary's encoded preview: the list row's
/// picture of where the workout went.
struct RouteThumbnail: View {
    let preview: String
    var size: CGFloat = 44

    var body: some View {
        Canvas { context, canvas in
            let coordinates = RouteMath.decode(preview)
            guard coordinates.count >= 2 else { return }
            let lat0 = (coordinates.map(\.lat).min()! + coordinates.map(\.lat).max()!) / 2
            let xs = coordinates.map { $0.lon * cos(lat0 * .pi / 180) }, ys = coordinates.map { -$0.lat }
            let minX = xs.min()!, maxX = xs.max()!, minY = ys.min()!, maxY = ys.max()!
            let span = max(maxX - minX, maxY - minY, 1e-6)
            let inset = canvas.width * 0.16
            let scale = (canvas.width - inset * 2) / span
            let offsetX = inset + (canvas.width - inset * 2 - (maxX - minX) * scale) / 2
            let offsetY = inset + (canvas.height - inset * 2 - (maxY - minY) * scale) / 2
            let points = zip(xs, ys).map { CGPoint(x: offsetX + ($0 - minX) * scale, y: offsetY + ($1 - minY) * scale) }
            var path = Path()
            path.addLines(points)
            context.stroke(path, with: .color(JcTheme.accent),
                           style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
            let first = points[0]
            context.fill(Path(ellipseIn: CGRect(x: first.x - 2.5, y: first.y - 2.5, width: 5, height: 5)),
                         with: .color(JcTheme.success))
        }
        .frame(width: size, height: size)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityHidden(true)
    }
}
