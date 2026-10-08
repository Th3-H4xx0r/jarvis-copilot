import Foundation

/// One control a wearable puts on its host's page — a lights switch on the car, say. The same
/// value drives the phone's tile, Jarvis's `<host>_set_control` skill and the CarPlay row, so a
/// control added once shows up in all three.
struct WearableControl: Identifiable {
    struct Option: Hashable {
        let id: String
        let title: String
    }

    enum Kind {
        case toggle(isOn: Bool)
        case button
        case level(value: Double, range: ClosedRange<Double>, step: Double, unit: String?)
        case choice(selected: String, options: [Option])
    }

    /// Unique on a host: `"<kind>.<name>"`, e.g. `"lights.power"`.
    let id: String
    let title: String
    let symbol: String
    var kind: Kind
    var enabled = true
    let perform: @MainActor (WearableControlValue) async throws -> Void
}

/// What a control is asked to do.
enum WearableControlValue: Equatable {
    case toggle(Bool)
    case press
    case level(Double)
    case choice(String)
}

extension WearableControl {
    /// The kind's name on the wire.
    var kindName: String {
        switch kind {
        case .toggle: return "toggle"
        case .button: return "button"
        case .level: return "level"
        case .choice: return "choice"
        }
    }

    /// A value sent by the agent (or a CarPlay row) for this control, or why it can't be used.
    func value(fromJSON raw: Any?) throws -> WearableControlValue {
        switch kind {
        case .button:
            return .press
        case .toggle:
            if let flag = raw as? Bool { return .toggle(flag) }
            if let word = (raw as? String)?.lowercased(),
               let flag = ["on": true, "true": true, "off": false, "false": false][word] {
                return .toggle(flag)
            }
            throw DeviceError.badArgument("\(id) takes true or false")
        case .level(_, let range, let step, _):
            let number = (raw as? NSNumber)?.doubleValue ?? (raw as? String).flatMap { Double($0) }
            guard let number, number.isFinite else {
                throw DeviceError.badArgument("\(id) takes a number from \(Self.format(range.lowerBound)) to \(Self.format(range.upperBound))")
            }
            return .level(Self.snap(number, range: range, step: step))
        case .choice(_, let options):
            guard let text = raw as? String,
                  let match = options.first(where: { $0.id == text })
                    ?? options.first(where: { $0.title.caseInsensitiveCompare(text) == .orderedSame })
            else {
                throw DeviceError.badArgument("\(id) takes one of: \(options.map(\.id).joined(separator: ", "))")
            }
            return .choice(match.id)
        }
    }

    /// A level with a finite range and a usable step, a choice with options. Anything else is
    /// dropped before it can reach a page, a skill or CarPlay.
    var isWellFormed: Bool {
        switch kind {
        case .toggle, .button: return true
        case .level(let value, let range, let step, _):
            return value.isFinite && range.lowerBound.isFinite && range.upperBound.isFinite
                && step.isFinite && step >= 0 && abs(range.lowerBound) < 1e9 && abs(range.upperBound) < 1e9
        case .choice(_, let options): return !options.isEmpty
        }
    }

    /// Clamped into the range and snapped to the step from its lower bound.
    static func snap(_ value: Double, range: ClosedRange<Double>, step: Double) -> Double {
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        guard step > 0 else { return clamped }
        let snapped = range.lowerBound + ((clamped - range.lowerBound) / step).rounded() * step
        // 0.1 steps drift (0.30000000000000004): round off the noise.
        return min((snapped * 1e6).rounded() / 1e6, range.upperBound)
    }

    static func format(_ number: Double) -> String {
        // `Int(_:)` traps on infinities and anything past Int's range.
        guard number.isFinite, abs(number) < 1e15, number == number.rounded() else { return String(format: "%g", number) }
        return String(Int(number))
    }

    /// The current value as a short phrase ("On", "60 %", "Party"); nil for a button.
    var valueText: String? {
        switch kind {
        case .toggle(let isOn): return isOn ? "On" : "Off"
        case .button: return nil
        case .level(let value, _, _, let unit):
            return Self.format(value) + (unit.map { " \($0)" } ?? "")
        case .choice(let selected, let options):
            return options.first { $0.id == selected }?.title ?? selected
        }
    }

    /// What the agent sees: the control, its current value and what it accepts.
    var stateJSON: [String: Any] {
        var out: [String: Any] = ["id": id, "title": title, "kind": kindName, "enabled": enabled]
        switch kind {
        case .toggle(let isOn): out["value"] = isOn
        case .button: break
        case .level(let value, let range, let step, let unit):
            out["value"] = value
            out["min"] = range.lowerBound
            out["max"] = range.upperBound
            out["step"] = step
            if let unit { out["unit"] = unit }
        case .choice(let selected, let options):
            out["value"] = selected
            out["options"] = options.map { ["id": $0.id, "title": $0.title] }
        }
        return out
    }
}
