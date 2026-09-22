import Foundation

/// The transcript as a value: utterances, insights, and the relabelling rules.
///
/// Split out of `LiveStore` because this is where the subtle behaviour lives — the
/// retroactive merge of design §5.2, the replace-not-append rule for a row the
/// server re-sends, and the ordering of a frame that arrives late — and none of it
/// needs a microphone, a socket or a clock to exercise.
struct LiveTranscript: Equatable, Sendable {

    private(set) var segments: [LiveSegment] = []
    private(set) var insights: [LiveInsight] = []
    /// The end-of-session wrap-up, when one has arrived. Held apart from the
    /// rows because it belongs after all of them whatever `seq` it claims — and
    /// it claims none (the server sends `seq: null`).
    private(set) var wrapUp: LiveWrapUp?

    /// Rows that now have a fact-check verdict beneath them.
    ///
    /// Maintained here rather than scanned for in the view, and kept on the
    /// TRANSCRIPT rather than the store, so `removeAll()` clears it with
    /// everything else — a rollover that left this behind would show "Fact-
    /// checked" against a brand-new conversation's rows.
    private(set) var factCheckedSeqs: Set<Int> = []

    /// Next local row id for an insight. Monotonic for the life of the
    /// transcript, so two notes stamped with the same `seq` are still two rows.
    private var nextInsightID = 1

    /// Both streams in one timeline. They share the `seq` space, which is what lets
    /// an insight sit at the point in the conversation it was about instead of
    /// piling up at the bottom.
    ///
    /// CACHED, not computed on access: a SwiftUI body reads this two or three times
    /// per update, and for an hours-long ambient transcript merging and re-sorting
    /// thousands of rows that often is work done on the main actor between audio
    /// frames. Rebuilt only when a row actually changes.
    private(set) var rows: [LiveRow] = []

    private mutating func rebuildRows() {
        // A TOTAL order, not just `seq`: `sorted` is not stable, several
        // insights share one `seq`, and an insight sits at the same `seq` as
        // the segment it is about. Without the tiebreak those rows could swap
        // places on any rebuild — which for SwiftUI is rows jumping while the
        // user reads. `tiebreak` is 0 for a segment, so a note always follows
        // the utterance it comments on.
        rows = (segments.map(LiveRow.segment) + insights.map(LiveRow.insight))
            .sorted { ($0.seq, $0.tiebreak) < ($1.seq, $1.tiebreak) }
    }

    /// The highest `seq` seen, which is what `after_seq` resumes from.
    var cursor: Int {
        max(segments.last?.seq ?? 0, insights.map(\.seq).max() ?? 0)
    }

    var isEmpty: Bool { segments.isEmpty && insights.isEmpty && wrapUp == nil }

    mutating func removeAll() {
        segments.removeAll()
        insights.removeAll()
        rows.removeAll()
        wrapUp = nil
        factCheckedSeqs.removeAll()
        // Not reset: a row id must stay unique for the life of the view, and a
        // clear followed by new insights would otherwise reuse ids SwiftUI has
        // already seen.
    }

    /// The wrap-up for this session. Replaces any earlier one — the server
    /// refuses to bill a second artifacts pass, so a second frame is a
    /// re-delivery of the same conclusion, not another one.
    mutating func apply(_ wrap: LiveWrapUp) {
        guard !wrap.isEmpty else { return }
        wrapUp = wrap
    }

    // MARK: - Rows

    /// Insert, or REPLACE the row with the same `seq`.
    ///
    /// Replace is the important half: a provisional row is re-sent once its speaker
    /// is resolved, and appending would leave the conversation saying everything
    /// twice.
    mutating func upsert(_ segment: LiveSegment) {
        if let index = segments.firstIndex(where: { $0.seq == segment.seq }) {
            segments[index] = segment
        } else if let index = segments.firstIndex(where: { $0.seq > segment.seq }) {
            // A late frame is PLACED, not appended: appended, it would read as
            // having been said last.
            segments.insert(segment, at: index)
        } else {
            segments.append(segment)
        }
        rebuildRows()
    }

    /// Insert an insight, absorbing only an exact re-delivery of one already
    /// held.
    ///
    /// Deliberately NOT replace-by-`seq`, which is right for segments and wrong
    /// here: a monitor window emits several notes and stamps them all with the
    /// same `seq`, so keying on it collapsed a window's whole output down to
    /// its last note.
    mutating func upsert(_ insight: LiveInsight) {
        if let index = insights.firstIndex(where: { $0.isSameNote(as: insight) }) {
            // Same note again (a resume replay). Keep the id the view is
            // already rendering rather than moving the card.
            var refreshed = insight
            refreshed.localID = insights[index].localID
            insights[index] = refreshed
            rebuildRows()
            return
        }
        var placed = insight
        placed.localID = nextInsightID
        nextInsightID += 1
        if LiveInsight.isFactCheck(kind: placed.kind) {
            factCheckedSeqs.insert(placed.aboutSeq)
        }
        // After every note already at this `seq`, so a window's notes read in
        // the order the watcher produced them; before anything later.
        if let index = insights.firstIndex(where: { $0.seq > placed.seq }) {
            insights.insert(placed, at: index)
        } else {
            insights.append(placed)
        }
        rebuildRows()
    }

    // MARK: - Speaker events

    /// Relabel rows already rendered.
    ///
    /// `merge` is retroactive on purpose (design §5.2): the server decided two ids
    /// were one person, so every row that carried either of them has to say so —
    /// including rows the user has already scrolled past.
    mutating func apply(_ event: LiveSpeakerEvent) {
        switch event.op {
        case .rename:
            guard !event.speakerID.isEmpty else { return }
            for index in segments.indices where segments[index].speakerID == event.speakerID {
                segments[index].speakerName = event.name
            }
        case .confirm:
            guard !event.speakerID.isEmpty else { return }
            for index in segments.indices where segments[index].speakerID == event.speakerID {
                segments[index].labelState = .confirmed
                if let name = event.name { segments[index].speakerName = name }
            }
        case .merge:
            let folded = Set(event.mergedFrom)
            guard !event.speakerID.isEmpty, !folded.isEmpty else { return }
            // The survivor's existing name, so a merge that carries no name of its
            // own does not blank the rows it absorbs.
            let survivingName = event.name
                ?? segments.first { $0.speakerID == event.speakerID }?.speakerName
            for index in segments.indices {
                guard let id = segments[index].speakerID else { continue }
                if folded.contains(id) {
                    segments[index].speakerID = event.speakerID
                    segments[index].speakerName = survivingName
                } else if id == event.speakerID, event.name != nil {
                    // The survivor's OWN rows take the name too. Without this the
                    // timeline reads "Alan, Alan, Speaker 1" for one person — the
                    // very inconsistency the merge exists to remove.
                    segments[index].speakerName = survivingName
                }
            }
        }
        rebuildRows()
    }
}
