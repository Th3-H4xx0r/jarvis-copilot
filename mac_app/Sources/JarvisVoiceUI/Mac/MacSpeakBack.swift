import Foundation
import Observation

/// A hand-off's answer, read out when it comes back.
///
/// A push-to-talk turn the quick model hands to a bigger one ends on "I'll have
/// a larger model look into that", and push to talk closes the conversation the
/// moment Jarvis has answered — so when the bigger model's answer is ready there
/// is no voice socket left to speak it. The server sends it to Jarvis.app on the
/// jobs feed instead, and the app hands it here (`speakText:heard:`): the small
/// voice island reads it in the JARVIS voice, the words lighting up as they're
/// said, through the voice store's own player — no mic, no socket.
@MainActor
@Observable
final class MacSpeakBack {
    static let shared = MacSpeakBack()

    /// Read out up to about this many characters, ending on a sentence: the whole
    /// answer is in the Agents tab, and a long one read in full runs for minutes.
    nonisolated static let spokenLimit = 700
    nonisolated static let restNote = "The rest is in the Agents tab."
    /// How long an answer waits for a conversation that's running (he's talking
    /// to Jarvis again) to end before it's dropped.
    static let waitForQuietSeconds = 60

    /// An answer is being read out: the small island's orb speaks.
    private(set) var speaking = false
    /// Bumped by every new answer and by `stop()`: a run that's been superseded
    /// gives up at its next step.
    @ObservationIgnored private var run = 0

    /// Read `text` out; `heard` (what he asked) sits above it as the subtitle.
    func speak(_ text: String, heard: String) {
        let lines = Self.spokenChunks(text)
        guard !lines.isEmpty else { return }
        run += 1
        let mine = run
        Task { @MainActor [weak self] in
            let store = VoiceStore.shared
            // A conversation in progress goes first: never talk over him.
            var waited = 0
            while store.isActive && waited < Self.waitForQuietSeconds * 10 {
                try? await Task.sleep(for: .milliseconds(100))
                waited += 1
                guard let self, mine == self.run else { return }
            }
            guard let self, mine == self.run, !store.isActive else { return }
            await self.play(lines, heard: heard, run: mine)
        }
    }

    /// Push to talk went down: he's talking now, the answer stops.
    func stop() {
        run += 1
        guard speaking else { return }
        speaking = false
        Task { await VoiceStore.shared.audio.stop() }
    }

    private func play(_ lines: [String], heard: String, run mine: Int) async {
        let store = VoiceStore.shared
        // Whatever an earlier answer left queued goes first.
        await store.audio.stop()
        guard mine == run, !store.isActive else { return }
        store.reply.reset()
        store.userTranscript = heard
        store.livePartial = ""
        store.toolStatus = nil
        store.error = nil
        // Each sentence its own clip and karaoke segment, like a reply.
        var tags: [Int] = []
        var spoken: [String] = []
        for line in lines {
            if let tag = store.reply.append(line) {
                tags.append(tag)
                spoken.append(line)
            }
        }
        guard !spoken.isEmpty else { return }
        speaking = true
        let api = store.voice
        let engine = store.settings.engine
        let voiceName = store.settings.voice
        var clips = [Data](repeating: Data(), count: spoken.count)
        await withTaskGroup(of: (Int, Data).self) { group in
            for (index, line) in spoken.enumerated() {
                group.addTask { (index, await api.synthesizeOrEmpty(text: line, voice: voiceName, engine: engine)) }
            }
            for await (index, data) in group { clips[index] = data }
        }
        guard mine == run, !store.isActive else { return finish(mine) }
        var anyAudio = false
        for (index, data) in clips.enumerated() where !data.isEmpty {
            store.reply.assignAudio(to: tags[index])
            store.audio.enqueueMp3(data, tag: tags[index])
            anyAudio = true
        }
        if clips.contains(where: \.isEmpty) { store.error = VoiceStore.ttsUnavailableNotice }
        // Played out — or cut off: a new turn stops the player and bumps `run`.
        while anyAudio, mine == run, !store.isActive, store.audio.isBusy {
            try? await Task.sleep(for: .milliseconds(150))
        }
        if mine == run, !store.isActive { store.reply.finalizeSpoken() }
        finish(mine)
    }

    /// Done: the small island folds a moment later (the same signal as the end
    /// of a push-to-talk answer).
    private func finish(_ mine: Int) {
        guard mine == run else { return }
        speaking = false
        NotificationCenter.default.post(name: MacPushToTalk.doneNotification, object: nil)
    }

    /// The answer as sentence-sized pieces to say: markdown stripped, a table's
    /// rows read as lists, cut at a sentence past `spokenLimit`.
    nonisolated static func spokenChunks(_ text: String) -> [String] {
        var lines: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("|") else {
                lines.append(raw)
                continue
            }
            let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            // The |---|---| rule under a table's header says nothing.
            if cells.isEmpty || cells.allSatisfy({ $0.allSatisfy { "-:".contains($0) } }) { continue }
            lines.append(cells.joined(separator: ", ") + ".")
        }
        var out: [String] = []
        var count = 0
        for chunk in voiceSplitForSpeech(voicePlainSpeech(lines.joined(separator: "\n"))) {
            if count > 0 && count + chunk.count > spokenLimit {
                out.append(restNote)
                break
            }
            out.append(chunk)
            count += chunk.count
        }
        return out
    }
}
