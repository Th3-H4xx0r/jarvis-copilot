import AppIntents
import Foundation
import WidgetKit

/// A widget design as the widget lists it.
struct WidgetDesignInfo: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var icon: String
}

enum WidgetDesignError: LocalizedError {
    case unreadable, badID(String)

    var errorDescription: String? {
        switch self {
        case .unreadable: return "That isn't a widget design."
        case .badID(let id): return "\"\(id)\" can't be a design id (lowercase letters, digits, - and _)."
        }
    }
}

/// Widget designs, cached in the App Group by the app (from the creator or the server) and only
/// read by the widget: `widgets/design-<id>.json` each, plus `widgets/index.json` to list them.
enum WidgetDesignCache {
    static var directory: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: JarvisShared.appGroupID)?
            .appendingPathComponent("widgets", isDirectory: true)
    }

    static func isValidID(_ id: String) -> Bool {
        guard let first = id.first, first.isLetter || first.isNumber, id.count <= 64 else { return false }
        return id.allSatisfy { ($0.isLetter && $0.isLowercase) || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    private static func file(_ id: String, in dir: URL) -> URL { dir.appendingPathComponent("design-\(id).json") }
    private static func indexFile(_ dir: URL) -> URL { dir.appendingPathComponent("index.json") }

    @discardableResult
    static func save(_ json: Data, in dir: URL? = directory) throws -> WidgetDesignInfo {
        guard let dir, let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let id = object["id"] as? String else { throw WidgetDesignError.unreadable }
        guard isValidID(id) else { throw WidgetDesignError.badID(id) }
        let info = WidgetDesignInfo(id: id, name: object["name"] as? String ?? id,
                                    icon: (object["icon"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "square.grid.2x2")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try json.write(to: file(id, in: dir), options: .atomic)
        var index = infos(in: dir)
        if let at = index.firstIndex(where: { $0.id == id }) { index[at] = info } else { index.append(info) }
        try writeIndex(index, in: dir)
        return info
    }

    static func load(_ id: String, in dir: URL? = directory) -> JCDesign? {
        rawJSON(id, in: dir).flatMap { try? JSONDecoder().decode(JCDesign.self, from: $0) }
    }

    static func rawJSON(_ id: String, in dir: URL? = directory) -> Data? {
        guard let dir, isValidID(id) else { return nil }
        return try? Data(contentsOf: file(id, in: dir))
    }

    static func remove(_ id: String, in dir: URL? = directory) {
        guard let dir, isValidID(id) else { return }
        try? FileManager.default.removeItem(at: file(id, in: dir))
        try? writeIndex(infos(in: dir).filter { $0.id != id }, in: dir)
    }

    static func infos(in dir: URL? = directory) -> [WidgetDesignInfo] {
        guard let dir, let data = try? Data(contentsOf: indexFile(dir)) else { return [] }
        return (try? JSONDecoder().decode([WidgetDesignInfo].self, from: data)) ?? []
    }

    private static func writeIndex(_ index: [WidgetDesignInfo], in dir: URL) throws {
        try JSONEncoder().encode(index).write(to: indexFile(dir), options: .atomic)
    }
}

extension WidgetSize {
    init(family: WidgetFamily) {
        switch family {
        case .systemSmall: self = .small
        case .systemMedium: self = .medium
        case .systemLarge: self = .large
        case .systemExtraLarge: self = .extraLarge
        case .accessoryCircular: self = .circular
        case .accessoryRectangular: self = .rectangular
        case .accessoryInline: self = .inline
        @unknown default: self = .medium
        }
    }
}

struct WidgetDesignEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Jarvis widget design"
    static let defaultQuery = WidgetDesignQuery()

    let id: String
    let name: String
    let icon: String

    init(_ info: WidgetDesignInfo) {
        id = info.id
        name = info.name
        icon = info.icon
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: .init(systemName: icon))
    }
}

struct WidgetDesignQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [WidgetDesignEntity] {
        WidgetDesignCache.infos().filter { identifiers.contains($0.id) }.map(WidgetDesignEntity.init)
    }

    func suggestedEntities() async throws -> [WidgetDesignEntity] {
        WidgetDesignCache.infos().map(WidgetDesignEntity.init)
    }
}

/// Which design a "Jarvis widget" shows, chosen when it is added (or by editing the widget).
struct ChooseWidgetDesignIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Choose a design"
    static let description = IntentDescription("A design from Jarvis → Settings → Widget creator.")

    @Parameter(title: "Design")
    var design: WidgetDesignEntity?
}
