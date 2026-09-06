import Foundation

/// One rendered scrollback line plus a **monotonic** id.
///
/// The id never repeats and never shifts: line 0 stays line 0 even after the
/// 2000-line cap has evicted a thousand rows above it. `ForEach(_, id: \.offset)`
/// re-identified every row whenever the top was trimmed, which threw away
/// SwiftUI's row reuse and the selection/scroll position with it.
struct TerminalBufferLine: Identifiable, Equatable {
    let id: Int
    let text: String
}

/// A VT100-lite line buffer for the server PTY's output.
///
/// The Flutter app fed `/api/terminal/output` straight into xterm.dart. We have
/// no terminal emulator on iOS and no third-party packages, so this keeps a plain
/// scrollback of lines and interprets only what the tmux/Claude-Code output
/// actually needs to stay readable:
///
/// * `CR` returns to column 0 and following writes **overwrite** (progress bars,
///   spinners), `LF`/`VT`/`FF` open a new line, `BS` steps back one cell (so the
///   classic `BS space BS` erase works), `TAB` snaps to the next 8-column stop.
/// * Escape sequences are **stripped**: CSI (`ESC [ … final`), OSC/DCS/APC
///   strings (`ESC ] … BEL|ST`), charset designators and two-character escapes.
///   The parser is stateful across `write` calls because SSE frames split
///   sequences mid-escape.
/// * The two erases worth honouring are kept — `EL` (`ESC [ K`) truncates/blanks
///   the current line and `ED 2/3` (`ESC [ 2J`) clears the buffer — because the
///   TUI repaints with them constantly and stripping them leaves duplicated junk.
///   `CUF`/`CUB` (`ESC [ n C|D`) move within the line. Everything else, including
///   absolute cursor positioning, is dropped: without a full screen model,
///   guessing would look worse than a flat log.
///
/// Trailing blank cells are trimmed when rendering, so an erase leaves no ragged
/// whitespace. `resize` does not reflow existing lines — it only changes where
/// subsequent output wraps (tmux repaints after a resize anyway).
struct TerminalBuffer {

    // MARK: Geometry

    private(set) var rows: Int
    private(set) var cols: Int
    let maxLines: Int

    init(rows: Int = 24, cols: Int = 80, maxLines: Int = 2000) {
        self.rows = max(1, rows)
        self.cols = max(1, cols)
        self.maxLines = max(1, maxLines)
    }

    /// Change the wrap width / reported height. Nonsense values are ignored so a
    /// zero-sized SwiftUI layout pass can't wreck the buffer.
    mutating func resize(rows newRows: Int, cols newCols: Int) {
        guard newRows > 0, newCols > 0 else { return }
        rows = newRows
        cols = newCols
        column = min(column, cols)
        pendingWrap = column >= cols
    }

    // MARK: Contents

    /// The rendered lines, oldest first; the LAST element is the live cursor
    /// line and is refreshed at the end of every `write`.
    ///
    /// This is the buffer's storage, not a derived view of it: `lines` is read on
    /// every SwiftUI body evaluation, and re-trimming 2000 `[Character]` rows into
    /// fresh `String`s each time was the terminal panel's whole frame budget.
    private var cache: [TerminalBufferLine] = [TerminalBufferLine(id: 0, text: "")]
    /// The cells of the line the cursor is on — the only thing that mutates
    /// between writes. Committed into `cache` at every newline and at the end of
    /// each `write` (that commit IS the cache invalidation).
    private var current: [Character] = []
    /// Next id to hand out. Monotonic for the life of the buffer, `clear()`
    /// included, so a repaint can never reuse an id the view still has on screen.
    private var nextLineId = 1
    private var column = 0
    /// xterm's deferred wrap: reaching the right margin does not open a new line
    /// until another printable character arrives, so a full-width line followed
    /// by CRLF doesn't leave a phantom blank line.
    private var pendingWrap = false

    /// Every line, oldest first, with its stable id — what the view's `ForEach`
    /// iterates. Free to read: it is the storage.
    var displayLines: [TerminalBufferLine] { cache }

    /// Every line, oldest first; the last one is where the cursor sits.
    var lines: [String] { cache.map(\.text) }

    var text: String { lines.joined(separator: "\n") }

    var isEmpty: Bool { cache.count == 1 && current.isEmpty }

    mutating func clear() {
        cache = [TerminalBufferLine(id: nextLineId, text: "")]
        nextLineId += 1
        current.removeAll()
        column = 0
        pendingWrap = false
    }

    // MARK: Writing

    /// Feed a chunk of PTY output.
    ///
    /// Iterates UNICODE SCALARS, not `Character`s: Swift folds `\r\n` into a
    /// single extended grapheme cluster, so a `Character` loop silently swallows
    /// every CRLF the server sends — which is most of them.
    mutating func write(_ chunk: String) {
        for scalar in chunk.unicodeScalars { feed(scalar) }
        commitCurrentLine()
    }

    /// Re-render the cursor line into the cache, keeping its id.
    private mutating func commitCurrentLine() {
        let last = cache.count - 1
        cache[last] = TerminalBufferLine(id: cache[last].id,
                                         text: Self.trimTrailingBlanks(current))
    }

    // MARK: Escape parsing

    private enum EscapeState {
        case ground
        /// Saw `ESC`, waiting for the introducer.
        case escape
        /// Inside `ESC [ …`, collecting parameters until the final byte.
        case csi
        /// Inside an OSC/DCS/SOS/PM/APC string, until `BEL` or `ESC \`.
        case string
        /// Saw `ESC` inside such a string — `\` ends it.
        case stringEscape
        /// A charset designator (`ESC ( B`) — swallow exactly one more byte.
        case charset
    }

    private var state: EscapeState = .ground
    private var csiParams = ""

    private mutating func feed(_ ch: Unicode.Scalar) {
        switch state {
        case .escape:
            switch ch {
            case "[": state = .csi; csiParams = ""
            case "]", "P", "X", "^", "_": state = .string
            case "(", ")", "*", "+", "-", ".", "/", "%", "#": state = .charset
            default: state = .ground // two-character escape: ESC =, ESC >, ESC M …
            }
            return
        case .charset:
            state = .ground
            return
        case .csi:
            // Final byte is anything in 0x40…0x7E; everything before it is a
            // parameter or intermediate byte.
            if ch.isASCII, ch.value >= 0x40, ch.value <= 0x7E {
                applyCSI(final: ch, params: csiParams)
                state = .ground
            } else {
                csiParams.unicodeScalars.append(ch)
            }
            return
        case .string:
            if ch == "\u{7}" { state = .ground }
            else if ch == "\u{1b}" { state = .stringEscape }
            return
        case .stringEscape:
            state = ch == "\\" ? .ground : .string
            return
        case .ground:
            break
        }

        switch ch {
        case "\u{1b}":
            state = .escape
        case "\r":
            column = 0
            pendingWrap = false
        case "\n", "\u{b}", "\u{c}":
            newline()
        case "\u{8}":
            if column > 0 { column -= 1 }
            pendingWrap = false
        case "\t":
            let stop = min(((column / 8) + 1) * 8, cols)
            while column < stop { put(" ") }
        case "\u{7}", "\u{7f}":
            break // bell, DEL
        default:
            // Remaining C0 controls carry no meaning for a log view.
            if ch.value < 0x20 { break }
            put(Character(ch))
        }
    }

    private mutating func applyCSI(final: Unicode.Scalar, params: String) {
        // Private/experimental parameter prefixes (DECSET & friends) never
        // change the text we render.
        if let f = params.first, "?<>=".contains(f) { return }
        let first = params.split(separator: ";", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let p0 = Int(first) ?? 0

        switch final {
        case "K":
            eraseInLine(p0)
        case "J":
            if p0 == 2 || p0 == 3 { clear() }
        case "C":
            column = min(column + max(1, p0), cols)
            pendingWrap = column >= cols
        case "D":
            column = max(0, column - max(1, p0))
            pendingWrap = false
        default:
            break
        }
    }

    /// `ESC [ Ps K`: 0 = cursor→end, 1 = start→cursor (inclusive), 2 = whole line.
    private mutating func eraseInLine(_ ps: Int) {
        switch ps {
        case 1:
            pad(upTo: column + 1)
            for i in 0...min(column, current.count - 1) { current[i] = " " }
        case 2:
            current.removeAll()
        default:
            if column < current.count { current.removeSubrange(column..<current.count) }
        }
        pendingWrap = false
    }

    // MARK: Cell writing

    private mutating func put(_ ch: Character) {
        if pendingWrap { newline() }
        pad(upTo: column)
        if column < current.count { current[column] = ch } else { current.append(ch) }
        column += 1
        if column >= cols { pendingWrap = true }
    }

    /// Grow the line with blanks so `column` is addressable (a CR + cursor-forward
    /// repaint can land past the end of a short line).
    private mutating func pad(upTo count: Int) {
        while current.count < count { current.append(" ") }
    }

    private mutating func newline() {
        commitCurrentLine()
        cache.append(TerminalBufferLine(id: nextLineId, text: ""))
        nextLineId += 1
        current = []
        column = 0
        pendingWrap = false
        // Trimmed inside the loop so one huge frame can't balloon memory — but as
        // ONE `removeFirst(k)`: k separate calls each shift the whole array.
        if cache.count > maxLines { cache.removeFirst(cache.count - maxLines) }
    }

    private static func trimTrailingBlanks(_ line: [Character]) -> String {
        var end = line.count
        while end > 0, line[end - 1] == " " || line[end - 1] == "\t" { end -= 1 }
        return String(line[0..<end])
    }
}
