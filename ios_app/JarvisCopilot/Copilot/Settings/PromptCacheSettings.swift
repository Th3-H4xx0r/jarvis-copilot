import SwiftUI

/// The server's prompt-cache retention (`/api/cache/config`): how long the
/// model provider keeps the prompt every chat, voice turn, harness step and
/// schedule shares cached — the same `prompt_caching.retention` key the web's
/// Settings → Keep prompts cached edits.
enum PromptCacheRetention: String, CaseIterable, Sendable {
    case standard
    case long

    var title: String {
        switch self {
        case .standard: return "5 minutes"
        case .long: return "1 hour"
        }
    }

    var subtitle: String {
        switch self {
        case .standard: return "The provider's usual cache"
        case .long: return "Stays warm through pauses between messages"
        }
    }

    /// The setting in a `/api/cache/config` reply (the default when absent).
    static func from(_ reply: [String: Any]) -> PromptCacheRetention {
        let raw = (reply["config"] as? [String: Any])?["retention"] as? String
        return raw.flatMap(PromptCacheRetention.init(rawValue:)) ?? .long
    }
}

struct PromptCacheAPI: Sendable {
    let api: JarvisAPI

    init(api: JarvisAPI = .shared) {
        self.api = api
    }

    func load() async throws -> [String: Any] {
        try await api.get("/api/cache/config").object()
    }

    /// The PUT body for a choice.
    static func body(for retention: PromptCacheRetention) -> [String: Any] {
        ["retention": retention.rawValue]
    }

    func save(_ retention: PromptCacheRetention) async throws -> [String: Any] {
        try await api.put("/api/cache/config", json: Self.body(for: retention)).object()
    }
}

/// The choice on screen: shown at once, PUT at once; a refusal puts back what
/// the server holds and says why (the same shape as `CompactionStore`).
@MainActor
@Observable
final class PromptCacheStore {
    static let shared = PromptCacheStore()

    private(set) var retention: PromptCacheRetention = .long
    private(set) var error = ""

    private let api: PromptCacheAPI

    init(api: PromptCacheAPI = PromptCacheAPI()) {
        self.api = api
    }

    func load() async {
        do {
            retention = PromptCacheRetention.from(try await api.load())
            error = ""
        } catch {
            self.error = apiErrorLine(error)
        }
    }

    func choose(_ value: PromptCacheRetention) async {
        guard value != retention else { return }
        let old = retention
        retention = value
        do {
            retention = PromptCacheRetention.from(try await api.save(value))
            error = ""
        } catch {
            retention = old
            self.error = apiErrorLine(error)
        }
    }
}

/// Settings → Keep prompts cached.
struct PromptCacheScreen: View {
    @State private var store = PromptCacheStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                GlassQuietLabel("Keep prompts cached")
                GlassGroup {
                    VStack(spacing: 0) {
                        ForEach(Array(PromptCacheRetention.allCases.enumerated()), id: \.element) { index, option in
                            Button {
                                Task { await store.choose(option) }
                            } label: {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(option.title)
                                            .font(JcText.body.weight(.semibold))
                                            .foregroundStyle(JcTheme.text)
                                        Text(option.subtitle)
                                            .font(.system(size: 12))
                                            .foregroundStyle(JcTheme.muted)
                                    }
                                    Spacer()
                                    if store.retention == option {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(JcTheme.accent)
                                    }
                                }
                                .padding(14)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if index < PromptCacheRetention.allCases.count - 1 {
                                Divider().opacity(0.3)
                            }
                        }
                    }
                }
                LiveSettingsNote("Every chat, voice turn, harness step and schedule on a model starts with the "
                               + "same prompt, and the provider keeps it cached so it isn't paid for in full again. "
                               + "Longer keeps it warm between pauses, so a new message re-sends less. Providers "
                               + "without a longer option ignore it.")
                if !store.error.isEmpty {
                    Text(store.error)
                        .font(.system(size: 12))
                        .foregroundStyle(JcTheme.danger)
                        .padding(.horizontal, 4)
                        .padding(.top, 12)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 6)
            .padding(.bottom, 36)
        }
        .jcScreen("Keep prompts cached")
        .task { await store.load() }
        .refreshable { await store.load() }
    }
}
