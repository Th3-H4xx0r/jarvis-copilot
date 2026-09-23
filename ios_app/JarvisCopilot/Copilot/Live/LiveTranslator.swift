import Foundation
#if canImport(Translation)
import Translation
#endif

/// Translating on the phone, because the fastest round trip is none.
///
/// Translation used to be a model call on the server made after an utterance
/// had already landed, and the gap was visible — several seconds between the
/// line appearing and its meaning. Apple's Translation framework runs on the
/// device and offline. Measured (Apple silicon, es→en and zh→en): about 330 ms
/// a line once its model is loaded, and 0.7–1.6 s for the FIRST line, which
/// pays for loading it.
///
/// Three things about it shape everything here:
///
/// * **Two ways to get a session.** On iOS 26 one can be built directly for a
///   pair whose languages are installed (`DirectTranslationSessions`): it needs
///   no view, so it works with the Live screen closed, and it is kept warm
///   between lines. Otherwise, or when a pack is missing, SwiftUI's
///   `.translationTask` is the only way — and the only one that can ask the
///   user to download a pack — which binds it to the Live screen's lifetime.
///   The server still covers everything the phone cannot.
/// * **A session is per language pair.** Changing the pair means a new session,
///   so work is grouped by source language.
/// * **`prepareTranslation()` does not load the model** (measured: the first line
///   after it still cost 740 ms). Translating something throwaway does, so
///   `warmUp` translates each expected language's own name when capture starts.
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

    /// Why an utterance came back without a translation. The two cases must
    /// not be treated alike: one is worth asking the server about, the other
    /// is the answer.
    enum Skipped {
        /// This phone cannot translate that pair — no language pack, or it
        /// failed. The server has more languages, so it should be asked.
        case cannot
        /// There is nothing to translate: the words are already in the target
        /// language. Asking anyone else produces "Hello, are you there?"
        /// translated into "Hello, are you there?", which is the bug this
        /// distinction exists to stop.
        case alreadyInTarget
    }

    /// Utterances that came back without a translation, and why.
    var onSkipped: ((Int, Skipped) -> Void)?

    /// What we are translating INTO, BCP-47.
    var target: String = "en"

    /// Sessions that need no view, when this OS can make them (iOS 26+). Nil
    /// means every pair goes through the `.translationTask` path.
    var direct: DirectTranslationSessions?

    private var pending: [Job] = []
    /// Pairs Apple has told us it cannot do. Asking again every utterance
    /// would mean a failed download prompt per line.
    private var unsupported: Set<String> = []
    /// Pairs the direct path could not serve because their languages are not
    /// on the phone. They go to the `.translationTask` path, which can ask to
    /// download them.
    private var viewPairs: Set<String> = []
    private var inFlight = false
    private var draining = false
    /// Languages already warmed this launch, and the sentinel `seq`s warm-ups
    /// run under — negative, so no callback ever reports one.
    private var warmed: Set<String> = []
    private var warmUpSeq = 0

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
            onSkipped?(seq, .cannot)
            return
        }
        let into = Self.primarySubtag(target)
        guard !into.isEmpty else {
            // No target language means no translation. Without this the
            // comparison below is "en" != "", which is true, so EVERY line
            // including English was sent to be translated — into whatever the
            // device felt like, which is how English got an English
            // "translation" under it.
            onSkipped?(seq, .cannot)
            return
        }
        let from = Self.primarySubtag(source)
        guard !from.isEmpty else {
            // No language on the row at all. The server may know better once
            // it has re-heard the audio, so it is worth asking.
            onSkipped?(seq, .cannot)
            return
        }
        guard from != into else {
            // Already the language we would translate into. Done, not deferred.
            onSkipped?(seq, .alreadyInTarget)
            return
        }
        guard !unsupported.contains(from) else {
            onSkipped?(seq, .cannot)
            return
        }
        guard !pending.contains(where: { $0.seq == seq }) else { return }
        pending.append(Job(seq: seq, text: words, source: from))
        if direct != nil, !viewPairs.contains(from) {
            drainDirect()
        } else {
            configureForNextPair()
        }
    }

    /// Load the models for the languages this recording expects, before anyone
    /// speaks them, so the first foreign line costs ~330 ms rather than the
    /// 0.7–1.6 s of loading. Only through the direct path: the view path would
    /// have to put a session up just for this.
    func warmUp(sources: [String]) {
        guard Self.isAvailable, direct != nil else { return }
        let into = Self.primarySubtag(target)
        guard !into.isEmpty else { return }
        for source in sources.map(Self.primarySubtag) where !source.isEmpty && source != into {
            guard !warmed.contains(source), !unsupported.contains(source),
                  let name = Locale(identifier: source).localizedString(forLanguageCode: source),
                  !name.isEmpty
            else { continue }
            warmed.insert(source)
            warmUpSeq -= 1
            // The language's own name is always real text in that language.
            pending.append(Job(seq: warmUpSeq, text: name, source: source))
        }
        drainDirect()
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
            guard await translate(job, with: session) else { return }
        }
    }

    /// Forget which pairs failed. A language pack the user installs later, or
    /// a new recording, deserves a fresh try.
    func reset() {
        pending.removeAll()
        unsupported.removeAll()
        viewPairs.removeAll()
        configuration = nil
        inFlight = false
    }

    // MARK: - The direct path

    /// Translate everything the direct path can serve, one line at a time, in
    /// the order it was asked for. A pair it cannot serve moves to the view path.
    private func drainDirect() {
        guard let direct, !draining else { return }
        draining = true
        Task { [weak self] in
            while let self, let job = self.pending.first(where: { !self.viewPairs.contains($0.source) }) {
                guard let runner = await direct.runner(source: job.source, target: self.target) else {
                    // Not installed on this phone. The view path can ask the user
                    // to download it; until then the server answers.
                    self.viewPairs.insert(job.source)
                    self.pending.removeAll { $0.source == job.source && $0.seq < 0 }
                    self.configureForNextPair()
                    continue
                }
                self.pending.removeAll { $0.seq == job.seq }
                _ = await self.translate(job, with: runner)
            }
            self?.draining = false
        }
    }

    /// One line through one session. False when the pair failed, which
    /// condemns it: the usual cause is a pack that is not installed and cannot
    /// be fetched, and retrying per utterance would ask forever.
    private func translate(_ job: Job, with session: TranslationRunner) async -> Bool {
        do {
            let done = try await session.translate(job.text)
            // A warm-up: loading the model was the point, the words are not.
            guard job.seq >= 0 else { return true }
            let clean = done.trimmingCharacters(in: .whitespacesAndNewlines)
            if clean.isEmpty || clean == job.text {
                // Identical output means it had nothing to change: the
                // words were already in the target language. That is an
                // ANSWER — handing it to the server instead produced
                // English "translated" into the same English.
                onSkipped?(job.seq, .alreadyInTarget)
            } else {
                onTranslated?(job.seq, clean)
            }
            return true
        } catch {
            let pair = job.source
            unsupported.insert(pair)
            if job.seq >= 0 { onSkipped?(job.seq, .cannot) }
            for orphan in pending where orphan.source == pair && orphan.seq >= 0 {
                onSkipped?(orphan.seq, .cannot)
            }
            pending.removeAll { $0.source == pair }
            JcLog.voice.notice("live: on-device translation unavailable for \(pair)")
            return false
        }
    }

    // MARK: - Private

    /// Point the task at whichever pair has work waiting.
    ///
    /// `force` is for the moment a session finishes: the configuration must
    /// change for SwiftUI to hand over a new one, so the same pair twice in a
    /// row needs an explicit nudge through nil.
    private func configureForNextPair(force: Bool = false) {
        guard !inFlight || force else { return }
        // With a direct path, only the pairs it handed over are this path's.
        guard let next = pending.first(where: { direct == nil || viewPairs.contains($0.source) }) else {
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

/// Sessions that need no view: one per pair, made on demand and kept.
///
/// A protocol so the routing between this and the view path can be tested
/// without a device or a language pack.
@MainActor
protocol DirectTranslationSessions: AnyObject {
    /// A session for this pair, or nil when its languages are not installed on
    /// the phone — which only the view path can do anything about.
    func runner(source: String, target: String) async -> TranslationRunner?
}

#if canImport(Translation)
/// iOS 26's `TranslationSession(installedSource:target:)`.
///
/// Prefers the low-latency model where the phone has it (iOS 26.4); it is a
/// separate download from the standard one, so where it is only "supported"
/// the standard model is used rather than failing the line.
@available(iOS 26.0, macOS 26.0, *)
@MainActor
final class InstalledTranslationSessions: DirectTranslationSessions {
    private var sessions: [String: TranslationSession] = [:]

    func runner(source: String, target: String) async -> TranslationRunner? {
        let key = source + ">" + target
        if let session = sessions[key] { return session }
        let from = Locale.Language(identifier: source)
        let into = Locale.Language(identifier: target)
        let session: TranslationSession
        if #available(iOS 26.4, macOS 26.4, *),
           await LanguageAvailability(preferredStrategy: .lowLatency)
               .status(from: from, to: into) == .installed {
            session = TranslationSession(installedSource: from, target: into,
                                         preferredStrategy: .lowLatency)
        } else if await LanguageAvailability().status(from: from, to: into) == .installed {
            session = TranslationSession(installedSource: from, target: into)
        } else {
            return nil
        }
        sessions[key] = session
        return session
    }
}

@available(iOS 18.0, macOS 15.0, *)
extension TranslationSession: TranslationRunner {
    func translate(_ text: String) async throws -> String {
        let response: Response = try await self.translate(text)
        return response.targetText
    }
}
#endif
