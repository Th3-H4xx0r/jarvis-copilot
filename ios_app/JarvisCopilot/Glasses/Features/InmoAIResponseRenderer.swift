import Foundation

/// One GO3 answer turn. Returned data is AiChat payload, without the outer envelope.
/// Create a fresh renderer for every question; answer updates must be cumulative.
struct InmoAIResponseRenderer {
    private var preparedQuestion: String?
    private var sentAnswer = Data()
    private var ended = false
    private var showingThinking = false

    mutating func update(question: String, answer: String, finished: Bool, thinking: Bool = false) throws -> [Data] {
        guard !ended else { return [] }
        guard preparedQuestion != nil || !question.isEmpty else { return [] }
        if let preparedQuestion, !question.isEmpty, preparedQuestion != question {
            throw InmoProtocolError.malformed("A new AI question requires a new renderer")
        }
        let answerBytes = Data(answer.utf8)
        guard answerBytes.starts(with: sentAnswer) else {
            throw InmoProtocolError.malformed("AI answer replaced text already sent to glasses")
        }

        var messages: [Data] = []
        if preparedQuestion == nil {
            // The observed official sequence creates the user row before the
            // assistant row. ASR alone does not create this conversation pair.
            messages.append(Self.chat(InmoWireCodec.string(2, question)))
            messages.append(Self.assistant(state: 6))
            preparedQuestion = question
        }
        let wasThinking = showingThinking
        if showingThinking && (!thinking || finished) {
            messages.append(Self.assistant(state: 3))
            showingThinking = false
        }
        let addedAnswer = answerBytes.count > sentAnswer.count
        if addedAnswer {
            let suffix = Data(answerBytes.dropFirst(sentAnswer.count))
            messages.append(Self.assistant(state: 4, text: suffix))
            sentAnswer = answerBytes
        }
        // Acknowledgement text/audio is not server completion. Reassert the
        // native thinking state after text deltas while work is still in flight.
        if thinking && !finished && (!wasThinking || addedAnswer) {
            messages.append(Self.chat(InmoWireCodec.uint(1, 1)
                + InmoWireCodec.uint(4, 1) + InmoWireCodec.uint(5, 1)))
            showingThinking = true
        }
        if finished {
            messages.append(Self.assistant(state: 5))
            ended = true
        }
        return messages
    }

    private static func chat(_ content: Data) -> Data {
        InmoWireCodec.uint(1, 1) + InmoWireCodec.bytes(3, content)
    }

    private static func assistant(state: UInt64, text: Data? = nil) -> Data {
        chat(InmoWireCodec.uint(1, 1)
             + (text.map { InmoWireCodec.bytes(2, $0) } ?? Data())
             + InmoWireCodec.uint(5, state))
    }
}
