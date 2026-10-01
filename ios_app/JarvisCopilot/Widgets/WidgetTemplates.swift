import Foundation

/// A starting point in the widget creator.
struct WidgetTemplate: Identifiable {
    let id: String
    let name: String
    let summary: String
    let symbol: String
    let area: String
    /// Builds the layouts; `buttons` are the Control Center buttons, for templates that run them.
    let build: ([ControlButtonInfo]) -> [String: WidgetLayout]

    func make(_ buttons: [ControlButtonInfo]) -> WidgetDesignDraft {
        WidgetDesignDraft(id: WidgetDesignDraft.slug(name), name: name, icon: symbol, tint: nil, layouts: build(buttons))
    }
}

/// The starters: one or two per area, each laid out for the sizes it suits.
enum WidgetTemplates {
    // Small builders keep the templates readable.
    private static func stat(_ source: String, _ label: String? = nil, color: String? = nil) -> WidgetBlock {
        WidgetBlock(kind: .stat, source: source, label: label, color: color)
    }
    private static func text(_ source: String? = nil, _ label: String? = nil, size: Double? = nil,
                             format: String? = nil) -> WidgetBlock {
        WidgetBlock(kind: .text, source: source, label: label, size: size, format: format)
    }
    private static func symbol(_ name: String, color: String? = nil, size: Double? = nil) -> WidgetBlock {
        WidgetBlock(kind: .symbol, symbol: name, color: color, size: size)
    }
    private static func gauge(_ source: String, _ label: String? = nil, color: String? = nil) -> WidgetBlock {
        WidgetBlock(kind: .gauge, source: source, label: label, color: color, max: 100)
    }
    private static func chart(_ source: String, _ style: String, _ label: String? = nil, height: Double = 60) -> WidgetBlock {
        WidgetBlock(kind: .chart, source: source, label: label, size: height, chartStyle: style)
    }
    private static func spark(_ source: String) -> WidgetBlock { WidgetBlock(kind: .sparkline, source: source) }
    private static func model(_ device: String, height: Double = 80) -> WidgetBlock {
        WidgetBlock(kind: .model, size: height, device: device)
    }
    private static func button(_ info: ControlButtonInfo) -> WidgetBlock {
        WidgetBlock(kind: info.keepsState == true ? .toggle : .button, button: info.id)
    }
    private static let spacer = WidgetBlock(kind: .spacer)
    private static func rows(_ rows: [WidgetBlock]...) -> WidgetLayout {
        WidgetLayout(rows: rows.map { WidgetRow(blocks: $0) })
    }

    private static let accent = "#3EC7C7"
    private static let heart = "#FF453A"
    private static let sleep = "#BF5AF2"

    static let all: [WidgetTemplate] = [
        WidgetTemplate(id: "body-battery", name: "Body battery", summary: "Today's score in a ring", symbol: "bolt.heart.fill",
                       area: "health") { _ in [
            "small": rows([gauge("health.score", color: accent)], [text("health.band", size: 13)]),
            "medium": rows([gauge("health.score", color: accent), stat("health.sleep_score", "Sleep"),
                            stat("health.recovery", "Recovery")], [text("health.analysis", size: 12)]),
            "circular": rows([gauge("health.score", color: accent)]),
            "rectangular": rows([stat("health.score", "Body battery")]),
            "inline": rows([text("health.score", format: "Body battery {}")]),
        ] },
        WidgetTemplate(id: "health-scores", name: "Health scores", summary: "Sleep, recovery, activity, vitals",
                       symbol: "heart.text.square.fill", area: "health") { _ in [
            "small": rows([stat("health.sleep_score", "Sleep"), stat("health.recovery", "Recovery")],
                          [stat("health.activity_score", "Activity"), stat("health.vitals_score", "Vitals")]),
            "medium": rows([stat("health.score", "Battery"), stat("health.sleep_score", "Sleep"),
                            stat("health.recovery", "Recovery"), stat("health.activity_score", "Activity")]),
        ] },
        WidgetTemplate(id: "sleep", name: "Last night's sleep", summary: "Asleep, stages and the week", symbol: "moon.zzz.fill",
                       area: "health") { _ in [
            "small": rows([symbol("moon.zzz.fill", color: sleep)], [stat("health.asleep", "Asleep")],
                          [stat("health.deep_minutes", "Deep"), stat("health.rem_minutes", "REM")]),
            "medium": rows([stat("health.asleep", "Asleep"), stat("health.deep_minutes", "Deep"),
                            stat("health.rem_minutes", "REM")], [chart("health.sleep_week", "bar")]),
            "rectangular": rows([stat("health.asleep", "Asleep")]),
        ] },
        WidgetTemplate(id: "steps", name: "Steps", summary: "Today and the last seven days", symbol: "figure.walk",
                       area: "health") { _ in [
            "small": rows([symbol("figure.walk", color: accent)], [stat("health.steps", "Steps")], [spark("health.steps_week")]),
            "medium": rows([stat("health.steps", "Steps today")], [chart("health.steps_week", "bar", height: 70)]),
            "circular": rows([gauge("health.steps")]),
            "inline": rows([text("health.steps", format: "{} steps")]),
        ] },
        WidgetTemplate(id: "heart", name: "Heart", summary: "Heart rate, HRV and blood oxygen", symbol: "heart.fill",
                       area: "health") { _ in [
            "small": rows([symbol("heart.fill", color: heart), stat("health.hr_avg")], [spark("health.hr_week")]),
            "medium": rows([stat("health.hr_avg", "Heart rate"), stat("health.hrv", "HRV"), stat("health.spo2", "SpO₂")],
                           [chart("health.hr_week", "line")]),
            "rectangular": rows([stat("health.hr_avg", "Heart rate")]),
        ] },
        WidgetTemplate(id: "x5", name: "X5 ring", summary: "3D model, battery and link", symbol: "circle.circle.fill",
                       area: "wearables") { _ in [
            "small": rows([model("x5ring", height: 70)], [stat("x5ring.battery", "X5")]),
            "medium": rows([model("x5ring", height: 100), stat("x5ring.battery", "Battery"),
                            text("x5ring.status", size: 13)]),
        ] },
        WidgetTemplate(id: "r12", name: "R12 ring", summary: "3D model, battery and link", symbol: "circle.circle",
                       area: "wearables") { _ in [
            "small": rows([model("ring", height: 70)], [stat("ring.battery", "R12")]),
            "medium": rows([model("ring", height: 100), stat("ring.battery", "Battery"), text("ring.status", size: 13)]),
        ] },
        WidgetTemplate(id: "wearables", name: "All wearables", summary: "Every device's link and battery",
                       symbol: "antenna.radiowaves.left.and.right", area: "wearables") { _ in [
            "medium": rows([symbol("circle.circle", size: 16), text("x5ring.name"), spacer, text("x5ring.battery", format: "{}%")],
                           [symbol("circle.circle", size: 16), text("ring.name"), spacer, text("ring.battery", format: "{}%")],
                           [symbol("waterbottle", size: 16), text("bottle.name"), spacer, text("bottle.battery", format: "{}%")]),
            "large": rows([symbol("circle.circle", size: 16), text("x5ring.name"), spacer, text("x5ring.status"),
                           text("x5ring.battery", format: "{}%")],
                          [symbol("circle.circle", size: 16), text("ring.name"), spacer, text("ring.status"),
                           text("ring.battery", format: "{}%")],
                          [symbol("waterbottle", size: 16), text("bottle.name"), spacer, text("bottle.status"),
                           text("bottle.battery", format: "{}%")],
                          [symbol("scalemass", size: 16), text("scale.name"), spacer, text("scale.status")],
                          [symbol("eyeglasses", size: 16), text("glasses.name"), spacer, text("glasses.status")]),
        ] },
        WidgetTemplate(id: "glasses", name: "Glasses", summary: "The glasses and their link", symbol: "eyeglasses",
                       area: "wearables") { _ in [
            "small": rows([model("glasses", height: 70)], [text("glasses.status", size: 13)]),
        ] },
        WidgetTemplate(id: "ask-jarvis", name: "Ask Jarvis", summary: "Your buttons and the last reply", symbol: "sparkles",
                       area: "chat") { buttons in
            let picked = Array(buttons.prefix(2)).map(button)
            let hint = text(nil, "Add buttons in Control Center", size: 12)
            return [
                "small": rows([symbol("sparkles", color: accent), text(nil, "Jarvis", size: 15)],
                              picked.isEmpty ? [hint] : [picked[0]]),
                "medium": rows([symbol("sparkles", color: accent), text("chat.last_reply", size: 12)],
                               picked.isEmpty ? [hint] : picked),
            ]
        },
        WidgetTemplate(id: "last-reply", name: "Last reply", summary: "What Jarvis said last", symbol: "text.bubble.fill",
                       area: "chat") { _ in [
            "small": rows([text("chat.last_reply", size: 13)]),
            "medium": rows([text("chat.last_title", size: 11), spacer, text("chat.last_at", size: 11)],
                           [text("chat.last_reply", size: 14)]),
            "rectangular": rows([text("chat.last_reply", size: 12)]),
        ] },
        WidgetTemplate(id: "coding", name: "Coding sessions", summary: "Working and waiting on you",
                       symbol: "chevron.left.forwardslash.chevron.right", area: "coding") { _ in [
            "small": rows([symbol("chevron.left.forwardslash.chevron.right", color: accent)],
                          [stat("coding.waiting", "Waiting on you")], [text("coding.summary", size: 12)]),
            "rectangular": rows([stat("coding.waiting", "Coding · waiting")]),
            "inline": rows([text("coding.summary")]),
        ] },
        WidgetTemplate(id: "server", name: "Jarvis server", summary: "The link to Jarvis", symbol: "server.rack",
                       area: "server") { _ in [
            "small": rows([symbol("server.rack", color: accent)], [text("server.status", size: 15)],
                          [text("time.updated", size: 11, format: "Updated {}")]),
            "inline": rows([text("server.status")]),
        ] },
        WidgetTemplate(id: "quick-actions", name: "Quick actions", summary: "Your Control Center buttons, on the Home Screen",
                       symbol: "square.grid.2x2.fill", area: "phone") { buttons in
            let picked = Array(buttons.prefix(4)).map(button)
            guard !picked.isEmpty else {
                return ["small": rows([symbol("square.grid.2x2.fill", color: accent)],
                                      [text(nil, "Add buttons in Control Center", size: 12)])]
            }
            let pairs = stride(from: 0, to: picked.count, by: 2).map { Array(picked[$0..<min($0 + 2, picked.count)]) }
            return ["small": WidgetLayout(rows: picked.prefix(2).map { WidgetRow(blocks: [$0]) }),
                    "medium": WidgetLayout(rows: pairs.map { WidgetRow(blocks: $0) })]
        },
        WidgetTemplate(id: "phone", name: "Phone & alarms", summary: "Battery and the next alarm", symbol: "alarm.fill",
                       area: "phone") { _ in [
            "small": rows([symbol("iphone", color: accent), stat("phone.battery")], [text("alarm.next", size: 13)]),
            "inline": rows([text("alarm.next")]),
        ] },
    ]
}
