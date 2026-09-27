import UIKit
import CoreLocation

/// The lens minimap the official app streams during guidance: 211×121 PNG, green on
/// black, heading-up, position at 50 % width / 60 % height, about 126 m across.
/// Route only (no road network — MapKit doesn't hand out road geometry).
enum NavigationMinimap {
    static let size = CGSize(width: 211, height: 121)
    private static let green = UIColor(red: 0, green: 1, blue: 0, alpha: 1)

    /// Guidance view around `position`, rotated so `heading` (degrees, 0 = north) points up.
    static func render(route: [CLLocationCoordinate2D], position: CLLocationCoordinate2D, heading: Double, metresAcross: Double = 126) -> Data? {
        let scale = size.width / metresAcross
        let theta = heading * .pi / 180
        func point(_ c: CLLocationCoordinate2D) -> CGPoint {
            let p = NavigationGeo.local(c, from: position)
            // Rotate the world by −heading so the direction of travel points up.
            let x = p.x * cos(theta) - p.y * sin(theta), y = p.x * sin(theta) + p.y * cos(theta)
            return CGPoint(x: size.width * 0.5 + x * scale, y: size.height * 0.6 - y * scale)
        }
        return draw {
            stroke(route.map(point), width: 3)
            let me = CGPoint(x: size.width * 0.5, y: size.height * 0.6)
            let arrow = UIBezierPath()
            arrow.move(to: CGPoint(x: me.x, y: me.y - 7)); arrow.addLine(to: CGPoint(x: me.x + 5, y: me.y + 5))
            arrow.addLine(to: CGPoint(x: me.x, y: me.y + 2)); arrow.addLine(to: CGPoint(x: me.x - 5, y: me.y + 5)); arrow.close()
            UIColor.black.setStroke(); arrow.lineWidth = 2; arrow.stroke()
            green.setFill(); arrow.fill()
        }
    }

    /// Whole-route overview for the arrival card: route fitted with 16 px padding, start and end dots.
    static func overview(route: [CLLocationCoordinate2D]) -> Data? {
        guard let origin = route.first, route.count > 1 else { return nil }
        let local = route.map { NavigationGeo.local($0, from: origin) }
        let xs = local.map(\.x), ys = local.map(\.y)
        let minX = xs.min()!, minY = ys.min()!
        let w = max(xs.max()! - minX, 1), h = max(ys.max()! - minY, 1)
        let scale = min((size.width - 32) / w, (size.height - 32) / h)
        let padX = ((size.width - 32) - w * scale) / 2, padY = ((size.height - 32) - h * scale) / 2
        let points = local.map { CGPoint(x: 16 + padX + ($0.x - minX) * scale, y: size.height - 16 - padY - ($0.y - minY) * scale) }
        return draw {
            stroke(points, width: 2.5)
            for (p, r) in [(points.first!, 4.0), (points.last!, 5.0)] {
                green.setFill(); UIBezierPath(ovalIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)).fill()
            }
        }
    }

    private static func draw(_ body: () -> Void) -> Data? {
        // Opaque (RGB) keeps the PNG about half the size of RGBA; every byte costs ~1.5 ms on this link.
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { r in
            UIColor.black.setFill(); r.fill(CGRect(origin: .zero, size: size))
            body()
        }.pngData()
    }
    private static func stroke(_ points: [CGPoint], width: CGFloat) {
        guard let first = points.first else { return }
        let path = UIBezierPath(); path.move(to: first)
        points.dropFirst().forEach { path.addLine(to: $0) }
        path.lineWidth = width; path.lineJoinStyle = .round; path.lineCapStyle = .round
        green.setStroke(); path.stroke()
    }
}
