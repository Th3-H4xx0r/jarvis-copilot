import Foundation

/// The model fields a voice TURN carries, and the label that names them.
///
/// Split out of `VoiceModelSelection.swift` — which is the Voice UI's picker
/// store and pulls in the model catalogue, the chat API and the phone's design
/// system — because these two are pure functions of the persisted selection and
/// the transport is their real caller. The Mac voice client builds this file and
/// not the picker.

/// The `model` / `model_provider` fields every voice turn carries. Port of
/// `_voiceModelFields()` — omitted entirely when nothing is selected, so the
/// server keeps using its own fast lane.
///
/// `model_provider` is the catalogue's canonical `provider_id` (see
/// ``VoiceModelStore/select(_:)``); the display name the picker groups under
/// does not route.
///
/// The transport should merge this into the realtime hello and the
/// `/api/voice/quality-turn` body.
func voiceTurnModelFields(_ selection: ModelSelection = .shared) -> [String: Any] {
    var fields: [String: Any] = [:]
    if let model = selection.model(for: .voice), !model.isEmpty { fields["model"] = model }
    if let provider = selection.provider(for: .voice), !provider.isEmpty {
        fields["model_provider"] = provider
    }
    return fields
}

/// A readable short name for a model id ("anthropic/claude-opus-4.7" →
/// "claude-opus-4.7"). Port of `_ModelChipState._label()`.
func voiceModelShortLabel(_ model: String?) -> String {
    guard let model, !model.isEmpty else { return "Auto" }
    var out = model
    if let slash = out.lastIndex(of: "/"), out.index(after: slash) < out.endIndex {
        out = String(out[out.index(after: slash)...])
    }
    if let colon = out.lastIndex(of: ":"), out.index(after: colon) < out.endIndex {
        out = String(out[out.index(after: colon)...])
    }
    return out
}
