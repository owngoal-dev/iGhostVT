import Foundation

// The tab's mode 2031 scanner (iGhostVT/Backend/Session/ThemeReportMode.swift)
// against output as a PTY hands it over: cut anywhere, mixed with other
// modes, queries and resets.

var failures: [String] = []

func check(_ chunks: [String], _ expected: Bool, _ description: String) {
    var mode = ThemeReportMode()
    for chunk in chunks {
        mode.feed(Data(chunk.utf8))
    }
    if mode.isEnabled == expected {
        print("  ok   \(description)")
    } else {
        print("  FAIL \(description): \(mode.isEnabled) != \(expected)")
        failures.append(description)
    }
}

print("theme reports: mode 2031")
check(["\u{1B}[?2031h"], true, "a set turns it on")
check(["text \u{1B}[?1004;20", "31h more"], true, "a set cut between two reads, among other modes")
check(["\u{1B}", "[", "?", "2031", "h"], true, "a set cut at every byte")
check(["\u{1B}[?2031h\u{1B}[?2031$p"], true, "a query changes nothing")
check(["\u{1B}[?2031h\u{1B}[?1;2031l"], false, "a reset among other modes turns it off")
check(["\u{1B}[?2031h\u{1B}c"], false, "a full reset turns it off")
check(["\u{1B}[?20310h", "\u{1B}[2031h", "\u{1B}[?2032h"], false, "another mode, or a public one, is not it")
check(["\u{1B}[?2031\u{1B}[?2004h"], false, "an escape inside a sequence starts the next one")
check(["\u{1B}[?\(String(repeating: "9", count: 40))h"], false, "a parameter too long to count is not it")
check([String(repeating: "x", count: 100_000) + "\u{1B}[?2031h"], true, "a set after a long run of text")

do {
    var mode = ThemeReportMode()
    mode.feed(Data("\u{1B}[?2031h".utf8))
    mode.reset()
    if mode.isEnabled {
        print("  FAIL a reset forgets the mode")
        failures.append("reset")
    } else {
        print("  ok   a reset forgets the mode")
    }
}

let reports = (ThemeReportMode.report(isDark: true), ThemeReportMode.report(isDark: false))
if reports == (Data("\u{1B}[?997;1n".utf8), Data("\u{1B}[?997;2n".utf8)) {
    print("  ok   the report says 1 for dark, 2 for light")
} else {
    print("  FAIL the report's encoding")
    failures.append("report")
}

if failures.isEmpty {
    print("theme reports: all checks passed")
} else {
    print("theme reports: \(failures.count) check(s) failed")
    exit(1)
}
