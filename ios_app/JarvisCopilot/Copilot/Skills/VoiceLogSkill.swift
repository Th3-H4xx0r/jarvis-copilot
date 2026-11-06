import Foundation

extension VoiceLogFile {
    /// `voice_log`: the newest lines of the phone's voice log, read over the bridge. The log
    /// times every mic start step by step (session switch, engine build, echo cancelling, the
    /// CarPlay card) and was only readable over the cable, which a phone in the car never is
    /// (2026-11-05: 5 s CarPlay mic starts, phone out of reach). The lines carry no
    /// transcripts and no audio.
    static func skill(_ log: VoiceLogFile = .shared) -> AnySkill {
        AnySkill(
            name: "voice_log",
            description: "Read the newest lines of this phone's voice diagnostics log: timings of "
                + "mic starts, audio session switches, CarPlay screen events. For diagnosing slow "
                + "or failed voice turns. No transcripts or audio.",
            inputSchema: SkillSchema.object([
                "lines": SkillSchema.integer(min: 1, max: maxTailLines,
                                             description: "How many of the newest lines (default 300)."),
                "contains": SkillSchema.string("Only lines containing this text, e.g. \"startup:\"."),
            ])
        ) { args in
            let wanted = SkillArgs.int(args, "lines") ?? 300
            let filter = SkillArgs.string(args, "contains")
            let lines = log.tail(lines: wanted, containing: filter.isEmpty ? nil : filter)
            return ["lines": lines, "count": lines.count]
        }
    }
}
