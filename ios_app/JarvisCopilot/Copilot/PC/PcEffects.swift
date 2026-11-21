import Foundation
import simd

/// The PC's lighting maths, identical to desktop_client/jc_client/pc_lighting/effects.py: the PC renders
/// frames with it and the 3D model glows with the same numbers. golden.json pins both — change a formula
/// in both places and regenerate it.
enum PcEffects {
    /// Python's `x % m` (always ≥ 0 for m > 0).
    static func mod(_ x: Double, _ m: Double) -> Double {
        let r = fmod(x, m)
        return r < 0 ? r + m : r
    }

    static func hex(_ s: String) -> SIMD3<Double> {
        let c = s.hasPrefix("#") ? String(s.dropFirst()) : s
        guard c.count == 6, let v = UInt32(c, radix: 16) else { return SIMD3(1, 1, 1) }
        return SIMD3(Double((v >> 16) & 0xff), Double((v >> 8) & 0xff), Double(v & 0xff)) / 255
    }

    /// Python's colorsys.hsv_to_rgb.
    static func hsv(_ h: Double, _ s: Double, _ v: Double) -> SIMD3<Double> {
        if s == 0 { return SIMD3(v, v, v) }
        let i = Int(h * 6), f = h * 6 - Double(i)
        let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
        switch i % 6 {
        case 0: return SIMD3(v, t, p)
        case 1: return SIMD3(q, v, p)
        case 2: return SIMD3(p, v, t)
        case 3: return SIMD3(p, q, v)
        case 4: return SIMD3(t, p, v)
        default: return SIMD3(v, p, q)
        }
    }

    /// 0…1 colour of LED `i` of `n` in the `segOrd`-th segment, `t` seconds into the effect.
    static func unit(effect: String, color: String, speed: Int, segOrd: Int, i: Int, n: Int, t: Double) -> SIMD3<Double> {
        let n = max(1, n), sp = Double(speed)
        switch effect {
        case "static":
            return hex(color)
        case "breathing":
            return hex(color) * (0.15 + 0.85 * (0.5 - 0.5 * cos(2 * .pi * t * sp / 10)))
        case "rainbow":
            return hsv(mod(Double(i) / Double(n) + Double(segOrd) * 0.12 + t * sp / 20, 1), 1, 1)
        case "spectrum":
            return hsv(mod(t * sp / 40, 1), 1, 1)
        case "comet":
            let head = mod(t * sp / 8 + Double(segOrd) * 0.25, 1) * Double(n)
            let value = max(0, 1 - mod(head - Double(i), Double(n)) / (0.35 * Double(n)))
            return hex(color) * value
        default:
            return SIMD3(0, 0, 0)
        }
    }

    /// 0…255 like the PC writes (Python round = half to even).
    static func colour(effect: String, color: String, speed: Int, segOrd: Int, i: Int, n: Int, t: Double) -> (UInt8, UInt8, UInt8) {
        let u = unit(effect: effect, color: color, speed: speed, segOrd: segOrd, i: i, n: n, t: t)
        func b(_ x: Double) -> UInt8 { UInt8(max(0, min(255, (x * 255).rounded(.toNearestOrEven)))) }
        return (b(u.x), b(u.y), b(u.z))
    }

    /// Every segment's LED colours (0…1) in map order, brightness applied, black when off.
    static func ledColours(state: PcLightingState, map: PcLedMap, now: Date) -> [[SIMD3<Float>]] {
        let t = (state.frozenAt ?? now.timeIntervalSince1970) - state.t0
        let scale = Float(max(0, min(100, state.brightness))) / 100
        return map.segments.enumerated().map { ord, seg in
            guard state.on, let part = PcPart(rawValue: seg.part) else {
                return Array(repeating: SIMD3<Float>(0, 0, 0), count: max(0, seg.count))
            }
            let light = state.light(part)
            return (0..<max(0, seg.count)).map { i in
                let u = unit(effect: light.effect, color: light.color, speed: light.speed, segOrd: ord, i: i, n: seg.count, t: t)
                return SIMD3<Float>(Float(u.x), Float(u.y), Float(u.z)) * scale
            }
        }
    }
}
