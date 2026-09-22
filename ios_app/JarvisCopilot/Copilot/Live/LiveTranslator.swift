import Foundation
#if canImport(Translation)
import Translation
#endif

/// Translating on the phone, because the fastest round trip is none.
///
/// Translation used to be a model call on the server made after an utterance
/// had already landed, and the gap was visible — several seconds between the
/// line appearing and its meaning. Apple's Translation framework runs on the
/// device, offline, in the tens of milliseconds, which is the only way this
/// gets to feel immediate.
///
/// Two things about it shape everything here:
///
/// * **A session cannot be constructed.** `TranslationSession` has no public
///   initialiser; the only way to get one is SwiftUI's `.translationTask`,
///   which binds it to a view's lifetime. So this translates while the Live
///   screen is on screen and not otherwise — which is exactly when someone is
///   watching for it, and why the server still does the same work for
///   everything else (a backgrounded recording, a closed screen, a language
///   Apple does not have).
/// * **A session is per language pair.** Changing the pair means a new session,
///   so work is grouped by source language and the configuration is swapped
///   between groups rather than per utterance.
///
/// This never decides WHETHER something should be translated. It is handed
/// utterances the transcript already believes are foreign, and it reports what
/// it made of them.
@MainActor
@Observable
final class LiveTranslator {

    /// One utterance waiting for its meaning.
    struct Job: Equatable, Sendable {
        let seq: Int
        let text: String
        /// BCP-47 of the language the words are in, as the transcript has it.
        let source: String
    }

    /// The pair the `.translationTask` should currently be configured for.
    /// Nil means there is nothing to do, which is the normal state.
    private(set) var configuration: TranslationConfig?

    /// Called with `(seq, translation)` for each utterance translated, on the
    /// main actor. The store decides what to do with it.
    var onTranslated: ((Int, String) -> Void)?

    /// Utterances this could not do — an unsupported pair, or a failure. The
    /// store hands these back to the server rather than dropping them.
    var onUnavailable: ((Int) -> Void)?

    /// What we are translating INTO, BCP-47.
    var target: String = "en"

    private var pending: [Job] = []
    /// Pairs Apple has told us it cannot do. Asking again every utterance
    /// would mean a failed download prompt per line.
    private var unsupported: Set<String> = []
    private var inFlight = false

    /// Whether this build and OS can translate on device at all.
    static var isAvailable: Bool {
        #if canImport(Translation)
        if #available(iOS 18.0, *) { return true }
        return false
        #else
        return false
        #endif
    }

    /// Queue one utterance. Cheap and synchronous — the caller is the transcript.
    func request(seq: Int, text: String, source: String) {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isAvailable, !words.isEmpty else {
            onUnavailable?(seq)
            return
        }
        let from = Self.primarySubtag(source)
        guard !from.isEmpty, from != Self.primarySubtag(target) else {
            // Same language, or no idea what it is: not this class's problem.
            onUnavailable?(seq)
            return
        }
        guard !unsupported.contains(from) else {
            onUnavailable?(seq)
            return
        }
        guard !pending.contains(where: { $0.seq == seq }) else { return }
        pending.append(Job(seq: seq, text: words, source: from))
        configureForNextPair()
    }

    /// Drain everything queued for the configured pair. Called from
    /// `.translationTask` with the session it just made.
    func run(_ session: TranslationRunner) async {
        guard let pair = configuration?.sourceCode else { return }
        inFlight = true
        defer {
            inFlight = false
            configureForNextPair(force: true)
        }
        while let job = pending.first(where: { $0.source == pair }) {
            pending.removeAll { $0.seq == job.seq }
            do {
                let done = try await session.translate(job.text)
                let clean = done.trimmingCharacters(in: .whitespacesAndNewlines)
                if clean.isEmpty || clean == job.text {
                    // Identical output means it had nothing to change — most
                    // often the text really was the target language already.
                    onUnavailable?(job.seq)
                } else {
                    onTranslated?(job.seq, clean)
                }
            } catch {
                // One failure condemns the PAIR, not just this line: the usual
                // cause is a language pack that is not installed and cannot be
                // fetched, and retrying per utterance would ask forever.
                unsupported.insert(pair)
                onUnavailable?(job.seq)
                for orphan in pending where orphan.source == pair {
                    onUnavailable?(orphan.seq)
                }
                pending.removeAll { $0.source == pair }
                JcLog.voice.notice("live: on-device translation unavailable for \(pair)")
                return
            }
        }
    }

    /// Forget which pairs failed. A language pack the user installs later, or
    /// a new recording, deserves a fresh try.
    func reset() {
        pending.removeAll()
        unsupported.removeAll()
        configuration = nil
        inFlight = false
    }

    // MARK: - Private

    /// Point the task at whichever pair has work waiting.
    ///
    /// `force` is for the moment a session finishes: the configuration must
    /// change for SwiftUI to hand over a new one, so the same pair twice in a
    /// row needs an explicit nudge through nil.
    private func configureForNextPair(force: Bool = false) {
        guard !inFlight || force else { return }
        guard let next = pending.first else {
            configuration = nil
            return
        }
        let wanted = TranslationConfig(sourceCode: next.source, targetCode: target)
        if configuration == wanted && force {
            // Same pair again: SwiftUI only remakes the session when the value
            // changes, so it has to go through nil first.
            configuration = nil
        }
        configuration = wanted
    }

    static func primarySubtag(_ code: String) -> String {
        code.trimmingCharacters(in: .whitespaces)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
            .first
            .map(String.init) ?? ""
    }
}

/// The pair a translation task is configured for.
///
/// Its own small type rather than `TranslationSession.Configuration` so the
/// store, the tests and this file can talk about pairs on any OS — the
/// framework type does not exist below iOS 18, and the view layer is the only
/// place that needs the real one.
struct TranslationConfig: Equatable, Sendable {
    var sourceCode: String
    var targetCode: String
}

/// What `LiveTranslator` needs from a session: turn text into other text.
///
/// A protocol so the queueing, grouping and give-up rules above can be tested
/// without a device, a language pack, or a SwiftUI view.
protocol TranslationRunner {
    func translate(_ text: String) async throws -> String
}

#if canImport(Translation)
@available(iOS 18.0, macOS 15.0, *)
extension TranslationSession: TranslationRunner {
    func translate(_ text: String) async throws -> String {
        let response: Response = try await self.translate(text)
        return response.targetText
    }
}
#endif
