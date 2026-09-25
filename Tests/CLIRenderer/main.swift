import Darwin
import Foundation

// The CLI's screen model. `capture` is only as truthful as this file, and
// it is the one part of the CLI with no daemon in the loop — so it is
// tested here on its own, with byte streams standing in for a shell.

var failures: [String] = []

func check(_ condition: Bool, _ description: String) {
    if condition {
        print("  ok   \(description)")
    } else {
        print("  FAIL \(description)")
        failures.append(description)
    }
}

/// Renders `stream` on a grid of the given size and returns the screen.
func render(
    _ stream: String,
    columns: UInt16 = 20,
    rows: UInt16 = 5,
    full: Bool = false,
) -> String {
    let renderer = ScreenRenderer(columns: columns, rows: rows)
    renderer.feed(stream)
    return full ? renderer.transcriptText() : renderer.screenText()
}

/// Raw bytes, for streams a Swift literal cannot express — a UTF-8
/// sequence cut in half by the replay buffer's front trim, say.
func renderBytes(_ bytes: [UInt8], columns: UInt16 = 20, rows: UInt16 = 5) -> String {
    let renderer = ScreenRenderer(columns: columns, rows: rows)
    renderer.feed(Data(bytes))
    return renderer.screenText()
}

let escape = "\u{1B}"

print("screen renderer: text and wrapping")
check(render("hello") == "hello", "plain text lands on the screen")
check(render("hello\r\nworld") == "hello\nworld", "CR LF starts a line")
check(render("hello\nworld") == "hello\n     world", "a bare LF does not return the carriage")
check(
    render("0123456789abcdefghijklmno", columns: 10, rows: 5) == "0123456789\nabcdefghij\nklmno",
    "text wraps at the last column",
)
check(
    render("0123456789\r\nnext", columns: 10, rows: 5) == "0123456789\nnext",
    "a line that exactly fills the width leaves no blank line behind",
)
check(render("a\u{8}b") == "b", "backspace moves back over a cell")
check(render("a\tb", columns: 20) == "a       b", "tab advances to the next stop")

print("screen renderer: scrolling and history")
check(
    render("one\r\ntwo\r\nthree\r\nfour\r\nfive\r\nsix", columns: 20, rows: 3)
        == "four\nfive\nsix",
    "output scrolls the screen",
)
check(
    render("one\r\ntwo\r\nthree\r\nfour\r\nfive\r\nsix", columns: 20, rows: 3, full: true)
        == "one\ntwo\nthree\nfour\nfive\nsix",
    "and the lines that scrolled off are the transcript",
)

print("screen renderer: cursor and erasing")
check(render("hello\(escape)[2J\(escape)[Hbye") == "bye", "erase-display and home clear the screen")
check(render("hello\(escape)[1;1Hj") == "jello", "cursor position overwrites in place")
check(render("hello\(escape)[3Gx") == "hexlo", "column address moves within the line")
check(render("hello\(escape)[1;3H\(escape)[K") == "he", "erase-to-end-of-line clears the rest")
check(render("hello\(escape)[1;3H\(escape)[1K") == "   lo", "erase-to-start clears up to the cursor")
check(render("hello\(escape)[1;3H\(escape)[2K") == "", "erase-line clears all of it")
check(render("hello\(escape)[1;3H\(escape)[2P") == "heo", "delete-character pulls the line left")
check(render("hello\(escape)[1;3H\(escape)[2@") == "he  llo", "insert-character pushes it right")
check(render("hello\(escape)[1;3H\(escape)[2X") == "he  o", "erase-character blanks in place")
check(render("hello\(escape)[s\(escape)[2;1Hthere\(escape)[u!") == "hello!\nthere", "the cursor saves and restores")
check(render("hello\(escape)7\(escape)[2;1Hthere\(escape)8!") == "hello!\nthere", "and so does the ESC 7 / ESC 8 pair")
check(
    render("line1\r\nline2\r\n\(escape)[=5u> prompt") == "line1\nline2\n> prompt",
    "the kitty keyboard protocol's CSI = 5 u is not a cursor restore",
)
check(
    render("line1\r\nline2\r\n\(escape)[>1u\(escape)[<u\(escape)[=0ux") == "line1\nline2\nx",
    "nor are the > and < forms",
)
check(render("hello\(escape)[?25lx") == "hellox", "a ? private mode with an unhandled final is ignored")

print("screen renderer: lines and regions")
check(
    render("one\r\ntwo\r\nthree\(escape)[1;1H\(escape)[L", columns: 20, rows: 3) == "one\ntwo",
    "insert-line pushes the screen down, off the bottom",
)
check(
    render("one\r\ntwo\r\nthree\(escape)[1;1H\(escape)[M", columns: 20, rows: 4) == "two\nthree",
    "delete-line pulls it up",
)
check(
    render("\(escape)[2;3r\(escape)[2;1Ha\r\nb\r\nc", columns: 20, rows: 4) == "b\nc",
    "output scrolls inside a scroll region, leaving the rows outside it alone",
)
check(
    render("one\r\ntwo\r\nthree\(escape)[2;3r\(escape)[2;1H\(escape)M", columns: 20, rows: 3)
        == "one\n\ntwo",
    "reverse index scrolls the region down",
)

print("screen renderer: alternate screen")
check(
    render("shell\(escape)[?1049hfullscreen\(escape)[?1049l") == "shell",
    "leaving the alternate screen puts the primary back",
)
check(
    render("shell\(escape)[?1049hfullscreen") == "fullscreen",
    "and while it is up, it is what is shown",
)
check(
    render("one\r\ntwo\r\nthree\r\nfour\(escape)[?1049hx\(escape)[?1049l", columns: 20, rows: 2, full: true)
        == "one\ntwo\nthree\nfour",
    "the alternate screen does not add to the transcript",
)

print("screen renderer: escapes that carry no text")
check(render("\(escape)]0;a title\u{7}hello") == "hello", "an OSC ended by BEL is swallowed")
check(render("\(escape)]7;file:///tmp\(escape)\\hello") == "hello", "an OSC ended by ST is swallowed")
check(render("\(escape)]133;A\u{7}$ \(escape)]133;B\u{7}ls") == "$ ls", "shell-integration marks leave only the text")
check(render("\(escape)[31mred\(escape)[0m") == "red", "colour is parsed and dropped")
check(render("\(escape)Pq#0;2;0;0;0\(escape)\\hello") == "hello", "a device-control string is swallowed")
check(render("\(escape)(0hello") == "hello", "a charset selection consumes only its own byte")

print("screen renderer: broken and partial input")
check(render("2;5Hhello") == "2;5Hhello", "a stream starting mid-sequence prints what is left of it")
check(render("\(escape)[1;2") == "", "a sequence cut off at the end leaves nothing behind")
check(render("ab\(escape)[3\r\ncd") == "ab\ncd", "a control byte inside a sequence abandons it and acts")
check(renderBytes([0x63, 0x61, 0x66, 0xC3]) == "caf", "a UTF-8 scalar cut short at the end is dropped")
check(renderBytes([0xA9, 0x63, 0x61, 0x66]) == "caf", "a stream starting on a continuation byte resyncs")
check(renderBytes([0x61, 0xEF, 0xBF, 0xBD, 0x62]) == "a\u{FFFD}b", "a genuine U+FFFD is placed and takes its cell")
check(renderBytes([0x61, 0xC0, 0x80, 0x62]) == "ab", "an overlong encoding is dropped")
check(renderBytes([0x61, 0xED, 0xA0, 0x80, 0x62]) == "ab", "and so is an encoded surrogate")

print("screen renderer: character width")
check(render("\u{4F60}\u{597D}", columns: 4, rows: 2) == "\u{4F60}\u{597D}", "CJK text renders")
check(
    render("\u{4F60}\u{597D}ab", columns: 4, rows: 2) == "\u{4F60}\u{597D}\nab",
    "a wide character occupies two columns",
)
check(render("e\u{301}") == "e\u{301}", "a combining mark joins the character before it")
check(
    render("\u{4E2D}\(escape)[2Gx", columns: 4, rows: 2) == " x",
    "writing over a wide glyph's right half blanks its left",
)
check(
    render("\u{4E2D}\(escape)[1Gx", columns: 4, rows: 2) == "x",
    "writing over its left half blanks its right",
)
check(
    render("\u{4E2D}\u{6587}\(escape)[2G\u{56FD}", columns: 4, rows: 2) == " \u{56FD}",
    "a wide glyph written across two others blanks both orphaned halves",
)
check(
    render("ab\u{4E2D}\(escape)[3Gxy", columns: 4, rows: 2) == "abxy",
    "overwriting both halves in turn leaves no gap",
)

print("screen renderer: prompt marks")
func marks(_ stream: String, columns: UInt16 = 20, rows: UInt16 = 5) -> ScreenRenderer.Transcript {
    let renderer = ScreenRenderer(columns: columns, rows: rows)
    renderer.feed(stream)
    return renderer.transcript()
}

let plain = marks("$ ls\r\na b c\r\n$")
check(plain.outputStart == nil && plain.promptStart == nil, "a session without shell integration has no marks")
let marked = marks("\(escape)]133;A\u{7}$ \(escape)]133;B\u{7}ls\r\n\(escape)]133;C\u{7}a b c\r\nd\r\n\(escape)]133;D;0\u{7}\(escape)]133;A\u{7}$ ")
check(marked.lines == ["$ ls", "a b c", "d", "$"], "the marks leave only the text")
check(marked.outputStart == 1, "the output-start mark is the row the output begins on")
check(marked.promptStart == 3, "the prompt-start mark is the row of the last prompt")
let scrolled = marks(
    "one\r\ntwo\r\n\(escape)]133;C\u{7}three\r\nfour\r\nfive\r\n\(escape)]133;A\u{7}$ ",
    columns: 20,
    rows: 3,
)
check(scrolled.lines == ["one", "two", "three", "four", "five", "$"], "a scrolled transcript keeps every line")
check(scrolled.outputStart == 2 && scrolled.promptStart == 5, "and its marks are transcript indices, not screen rows")
let leading = marks("\r\n\r\n\(escape)]133;C\u{7}out\r\n\(escape)]133;A\u{7}$ ")
check(
    leading.lines == ["out", "$"] && leading.outputStart == 0 && leading.promptStart == 1,
    "blank rows trimmed off the top shift the indices with them",
)
let pending = marks("$ sleep\r\n\(escape)]133;C\u{7}")
check(pending.lines == ["$ sleep"] && pending.outputStart == 1, "a mark on a still-blank row points past the last line")
let alternate = marks("\(escape)]133;A\u{7}$ \(escape)[?1049h\(escape)]133;C\u{7}x\(escape)[?1049l")
check(
    alternate.promptStart == 0 && alternate.outputStart == nil,
    "a mark on the alternate screen is not on the transcript",
)
let erased = marks(
    "\(escape)]133;C\u{7}gone\r\nx\r\n\(escape)[3J\(escape)[H\(escape)]133;A\u{7}$ ",
    columns: 20,
    rows: 2,
)
check(
    erased.lines == ["$"] && erased.outputStart == nil && erased.promptStart == 0,
    "a mark whose row was erased with the scrollback is gone",
)

print("key names")
check(KeyNames.bytes(for: "C-?") == [0x7F], "C-? is DEL")
check(KeyNames.bytes(for: "C-_") == [0x1F], "C-_ is unit separator")
check(KeyNames.bytes(for: "M-C-?") == [0x1B, 0x7F], "M-C-? is Meta-DEL")

if failures.isEmpty {
    print("cli renderer: all checks passed")
    exit(EXIT_SUCCESS)
} else {
    print("cli renderer: \(failures.count) failure(s)")
    for failure in failures {
        print("  - \(failure)")
    }
    exit(EXIT_FAILURE)
}
