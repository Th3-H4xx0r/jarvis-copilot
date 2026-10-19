import Foundation

/// A phone-side device as the action picker sees it.
struct ActionPickerDevice {
    let id: String
    let model: String
    let capabilities: [DeviceCapability]
    var unavailable: [UnavailableCapability] = []
}

/// A row that needs values before it can be saved.
enum ActionPickerForm {
    /// A catalogue action with one value to fill in (a timer's minutes, a link).
    case catalogue(RingActionOption)
    case wearable(deviceID: String, model: String, capability: DeviceCapability)
    case serverDevice(deviceID: String, name: String, capability: DeviceCapability)
    /// Disarm, silence or a car command: saved with its Skip Face ID choice.
    case secure(RingAction)
}

struct ActionPickerRow: Identifiable {
    enum Kind {
        /// One tap saves it.
        case pick(RingAction)
        case form(ActionPickerForm)
    }

    let id: String
    let title: String
    let detail: String
    let kind: Kind
    /// Why it can't be picked right now; the row is shown greyed with this.
    var unavailable: String? = nil
    /// Tool name and section, so search finds "bottle_sterilise" as well as "Sterilise now".
    var searchText = ""

    /// Whether `current` is this row's action (ticked in the list).
    func matches(_ current: RingAction) -> Bool {
        switch (kind, current) {
        case (.pick(.skill(let id, _)), .skill(let other, _)): return id == other
        case (.pick(let action), _): return action == current
        case (.form(.catalogue(let option)), .skill(let other, _)): return option.id == other
        case (.form(.wearable(let device, _, let capability)), .wearable(let other, let skill, _)):
            return device == other && capability.name == skill
        case (.form(.serverDevice(let device, _, let capability)), .serverDevice(let other, let skill, _)):
            return device == other && capability.name == skill
        case (.form(.secure(.door(let command, _))), .door(let other, _)): return command == other
        case (.form(.secure(.car(let command, _))), .car(let other, _)): return command == other
        default: return false
        }
    }
}

struct ActionPickerSection: Identifiable {
    let id: String
    let title: String
    let symbol: String
    var rows: [ActionPickerRow]
}

/// Every action a button, switch or ring gesture can run, grouped one section per device.
enum ActionPickerIndex {
    /// Tools the server calls on the phone itself — offering them as buttons would only confuse.
    static let hiddenSkills: Set<String> = ["door_alarm_ring", "door_show_alarm", "door_show_approvals",
                                            "car_show_approvals"]

    /// The tool-name prefixes that only repeat the device's name.
    private static let prefixes: Set<String> = ["ring", "x5", "band", "bottle", "scale", "glasses", "esp32", "pod",
                                                "dashcam", "lights", "car", "wearables", "door"]
    private static let phoneGroups: Set<String> = ["Phone", "Apps", "Media"]

    static func sections(devices: [ActionPickerDevice], serverDevices: [ServerDevice],
                         catalogue: [RingActionOption] = RingActionCatalogue.options) -> [ActionPickerSection] {
        var out: [ActionPickerSection] = []
        let counts = Dictionary(grouping: devices, by: \.model).mapValues(\.count)
        let ringID = devices.first { $0.capabilities.contains { $0.name == "ring_measure" } }?.id
        let hubID = devices.first { $0.model == "Jarvis Wearables" }?.id

        func catalogueRows(_ groups: Set<String>, section: String) -> [ActionPickerRow] {
            catalogue.filter { groups.contains($0.group) }.map { option in
                ActionPickerRow(id: "catalogue.\(option.id)", title: option.label, detail: option.note ?? "",
                          kind: option.parameter == nil ? .pick(.skill(id: option.id, arguments: [:]))
                                                        : .form(.catalogue(option)),
                          searchText: "\(option.skill) \(option.group) \(section)")
            }
        }

        // The phone first, then each device in the order it registered.
        let phones = devices.filter { $0.model == "iPhone" }
        if phones.isEmpty {
            out.append(ActionPickerSection(id: "iphone", title: "iPhone", symbol: "iphone",
                                     rows: catalogueRows(phoneGroups, section: "iPhone")))
        }
        for device in phones + devices.filter({ $0.model != "iPhone" }) {
            let (title, symbol) = label(device.model)
            let name = (counts[device.model] ?? 0) > 1 ? "\(title) · \(device.id.suffix(4))" : title
            var rows: [ActionPickerRow] = []
            var covered: Set<String> = []
            if device.model == "iPhone" {
                rows += catalogueRows(phoneGroups, section: name)
                // A tool the catalogue only uses with fixed values (media_control "toggle",
                // phone_control "volume") keeps its own row for everything else it does.
                let phoneEntries = catalogue.filter { phoneGroups.contains($0.group) }
                covered = Set(phoneEntries.map(\.skill)).filter { skill in
                    phoneEntries.filter { $0.skill == skill }.allSatisfy(\.arguments.isEmpty)
                }
            }
            if device.id == hubID {
                rows += catalogueRows(["Wearables"], section: name)
                covered.insert("wearables_keep_alive")
            }
            if device.id == ringID { rows += catalogueRows(["Ring"], section: name) }
            if device.model == DoorAlarmDevice.model { rows += doorRows() }
            if device.model == CarDevice.model { rows += carRows() }
            rows += deviceRows(device, sectionTitle: name, skipping: covered)
            guard !rows.isEmpty else { continue }
            out.append(ActionPickerSection(id: "device.\(device.id)", title: name, symbol: symbol, rows: rows))
        }
        if ringID == nil {
            let rows = catalogueRows(["Ring"], section: "Ring")
            if !rows.isEmpty { out.append(ActionPickerSection(id: "ring", title: "Ring", symbol: "circle.circle", rows: rows)) }
        }
        for board in serverDevices {
            let rows = board.capabilities.filter { !hiddenSkills.contains($0.name) }
                .sorted { $0.name < $1.name }
                .map { capability in
                    ActionPickerRow(id: "server.\(board.id).\(capability.name)", title: title(of: capability.name),
                              detail: firstSentence(capability.description),
                              kind: .form(.serverDevice(deviceID: board.id, name: board.name, capability: capability)),
                              unavailable: board.online ? nil : "\(board.name) is offline right now",
                              searchText: "\(capability.name) \(board.name)")
                }
            guard !rows.isEmpty else { continue }
            let pod = board.capabilities.contains { $0.name.hasPrefix("pod_") }
            out.append(ActionPickerSection(id: "server.\(board.id)", title: board.name,
                                     symbol: pod ? "circle.hexagongrid" : "cpu", rows: rows))
        }
        // The alarm and the car live on the server: always offered, set up or not.
        if !devices.contains(where: { $0.model == DoorAlarmDevice.model }) {
            out.append(ActionPickerSection(id: "door", title: "Door alarm", symbol: "lock.shield", rows: doorRows()))
        }
        if !devices.contains(where: { $0.model == CarDevice.model }) {
            out.append(ActionPickerSection(id: "car", title: "Car", symbol: "car.fill", rows: carRows()))
        }
        return out
    }

    /// Sections with a row matching every word of `query`; an empty query keeps everything.
    static func filter(_ sections: [ActionPickerSection], query: String) -> [ActionPickerSection] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return sections }
        return sections.compactMap { section in
            var kept = section
            kept.rows = section.rows.filter { row in
                let haystack = "\(row.title) \(row.detail) \(section.title) \(row.searchText)".lowercased()
                return words.allSatisfy(haystack.contains)
            }
            return kept.rows.isEmpty ? nil : kept
        }
    }

    // MARK: rows

    static func doorRows() -> [ActionPickerRow] {
        DoorButtonCommand.allCases.map { command in
            let action = RingAction.door(command)
            return ActionPickerRow(id: "door.\(command.rawValue)", title: command.title,
                             detail: command.needsFaceID ? "Face ID, or skip it for this button" : "",
                             kind: command.needsFaceID ? .form(.secure(action)) : .pick(action),
                             searchText: "door alarm security \(command.rawValue)")
        }
    }

    static func carRows() -> [ActionPickerRow] {
        CarButtonCommand.all.map { command in
            let action = RingAction.car(command: command)
            let secure = CarButtonCommand.needsFaceID(command)
            return ActionPickerRow(id: "car.\(command)", title: CarButtonCommand.title(command),
                             detail: secure ? "Face ID, or skip it for this button" : "",
                             kind: secure ? .form(.secure(action)) : .pick(action),
                             searchText: "car toyota \(command)")
        }
    }

    private static func deviceRows(_ device: ActionPickerDevice, sectionTitle: String, skipping covered: Set<String>) -> [ActionPickerRow] {
        // A tool that is also listed as unavailable (glasses settings: list only, until Experimental
        // Controls is on) shows once, greyed.
        let greyedNames = Set(device.unavailable.map(\.capability.name))
        let usable = device.capabilities.filter {
            !hiddenSkills.contains($0.name) && !covered.contains($0.name) && !greyedNames.contains($0.name)
        }
        var quick: [ActionPickerRow] = []
        var rest: [ActionPickerRow] = []
        for capability in usable {
            for one in WearableQuickActions.actions(for: capability) {
                quick.append(ActionPickerRow(id: "quick.\(device.id).\(capability.name).\(one.label)", title: one.label,
                                       detail: "", kind: .pick(.wearable(deviceID: device.id, skill: capability.name,
                                                                         arguments: one.arguments)),
                                       searchText: "\(capability.name) \(sectionTitle)"))
            }
            rest.append(ActionPickerRow(id: "tool.\(device.id).\(capability.name)", title: title(of: capability.name),
                                  detail: firstSentence(capability.description),
                                  kind: .form(.wearable(deviceID: device.id, model: device.model, capability: capability)),
                                  searchText: "\(capability.name) \(sectionTitle)"))
        }
        let greyed = device.unavailable.filter { !hiddenSkills.contains($0.capability.name) }.map { entry in
            ActionPickerRow(id: "tool.\(device.id).\(entry.capability.name)", title: title(of: entry.capability.name),
                      detail: firstSentence(entry.capability.description),
                      kind: .form(.wearable(deviceID: device.id, model: device.model, capability: entry.capability)),
                      unavailable: entry.reason, searchText: "\(entry.capability.name) \(sectionTitle)")
        }
        return quick + (rest + greyed).sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// "bottle_sterilise" → "Sterilise"; "clipboard_read" → "Clipboard read".
    static func title(of skill: String) -> String {
        var words = skill.split(separator: "_").map(String.init)
        if words.count > 1, prefixes.contains(words[0]) { words.removeFirst() }
        let text = words.joined(separator: " ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    static func firstSentence(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        let end = flat.range(of: ". ")?.lowerBound ?? flat.endIndex
        let sentence = String(flat[..<end])
        return sentence.count > 110 ? String(sentence.prefix(107)) + "…" : sentence
    }

    /// The section name and icon for a device model.
    static func label(_ model: String) -> (String, String) {
        switch model {
        case "iPhone": return ("iPhone", "iphone")
        case "Colmi R12": return ("Ring", "circle.circle")
        case "X5 smart ring": return ("X5 ring", "circle.circle")
        case "HBand smart band": return ("Band", "applewatch.side.right")
        case "VSITOO S1 Pro": return ("Bottle", "waterbottle")
        case "Etekcity ESF551": return ("Scale", "scalemass")
        case "INMO GO3": return ("Glasses", "eyeglasses")
        case "Jarvis ESP32 DevKit V1": return ("ESP32 board", "cpu")
        case "Jarvis Wearables": return ("Wearables", "dot.radiowaves.left.and.right")
        case "Dashcam": return ("Dashcam", "video")
        case "Car lights (Magic Lantern)": return ("Car lights", "lightbulb.led")
        case DoorAlarmDevice.model: return ("Door alarm", "lock.shield")
        case CarDevice.model: return ("Car", "car.fill")
        default: return (model, "sensor")
        }
    }
}
