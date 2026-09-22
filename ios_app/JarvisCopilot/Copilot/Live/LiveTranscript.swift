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
        rows = (segments.map(LiveRow.segment) + insights.map(LiveRow.insight))
            .sorted { $0.seq < $1.seq }
    }

    /// The highest `seq` seen, which is what `after_seq` resumes from.
    var cursor: Int {
        max(segments.last?.seq ?? 0, insights.map(\.seq).max() ?? 0)
    }

    var isEmpty: Bool { segments.isEmpty && insights.isEmpty }

    mutating func removeAll() {
        segments.removeAll()
        insights.removeAll()
        rows.removeAll()
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

    mutating func upsert(_ insight: LiveInsight) {
        if let index = insights.firstIndex(where: { $0.seq == insight.seq }) {
            insights[index] = insight
        } else if let index = insights.firstIndex(where: { $0.seq > insight.seq }) {
            insights.insert(insight, at: index)
        } else {
            insights.append(insight)
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
