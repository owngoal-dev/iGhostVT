/// What a terminal is left holding by a session's output — the part of it a
/// replay cannot rebuild by itself. `TerminalStreamTracker` keeps it current
/// as output goes by; `preamble()` writes it back as sequences, so a
/// terminal that is about to read a replay starting mid-session is first put
/// in the state the session's earlier output left it in.
///
/// Everything here mirrors what Ghostty does with the same sequence
/// (`Terminal.zig`, `termio/stream_handler.zig`) at the commit libghostty-spm
/// pins, and only what Ghostty implements is kept: a mode Ghostty ignores is
/// ignored here too.
///
/// A setting is kept once it was ever touched, at its current value — the
/// default included. The preamble may be read by a terminal that has already
/// shown this session further along (a link that came back after the bytes
/// it missed were trimmed), and that terminal has to be put back exactly;
/// a setting the session never touched is the terminal's default on both.
struct TerminalReplayState {
    /// The DEC private modes kept, and their defaults. The alternate-screen
    /// modes (47, 1047, 1049) and the cursor save (1048) are screen
    /// switches and cursor saves, not settings; 2026 is a frame in flight
    /// that a replay must never leave open, and 3 resizes the grid. The
    /// mouse modes are kept as the one event mode and the one format
    /// Ghostty derives from them (`mouseEvent`, `mouseFormat`).
    static let trackedDECModes: Set<UInt16> = [
        1, 4, 5, 6, 7, 8, 12, 25, 40, 45, 66, 67, 69, 1004, 1007, 1035, 1036, 1039,
        1045, 2004, 2027, 2031, 2033, 2048, 5522,
    ]
    static let mouseEventModes: Set<UInt16> = [9, 1000, 1002, 1003]
    static let mouseFormatModes: Set<UInt16> = [1005, 1006, 1015, 1016]
    static let alternateScreenModes: Set<UInt16> = [47, 1047, 1049]
    static let trackedANSIModes: Set<UInt16> = [2, 4, 12, 20]

    static func defaultDECMode(_ mode: UInt16) -> Bool {
        switch mode {
        case 7, 25, 1007, 1035, 1036: true
        default: false
        }
    }

    static func defaultANSIMode(_ mode: UInt16) -> Bool {
        mode == 12
    }

    /// G0–G3 and which of them GL and GR invoke. A slot holds 0 for
    /// Ghostty's initial UTF-8 set, or the final byte that designated it
    /// (`B` ASCII, `A` British, `0` DEC special graphics).
    struct Charsets: Equatable {
        var slots: [UInt8] = [0, 0, 0, 0]
        var gl: UInt8 = 0
        var gr: UInt8 = 2
    }

    /// The SGR sequences since the pen was last reset, each as its
    /// parameter bytes. A reset empties it; past `maximumPenSequences` the
    /// oldest go, which can only lose an attribute a later one did not set.
    typealias Pen = [[UInt8]]
    static let maximumPenSequences = 16

    struct Cursor: Equatable {
        var pen: Pen = []
        var charsets = Charsets()
        var origin = false
    }

    /// Ghostty's kitty keyboard flag stack (`kitty/key.zig`): eight
    /// entries, the index wrapping both ways.
    struct KittyFlags: Equatable {
        var flags: [UInt8] = Array(repeating: 0, count: 8)
        var index = 0

        mutating func push(_ value: UInt8) {
            index = (index + 1) & 7
            flags[index] = value & 0x1F
        }

        mutating func pop(_ count: UInt16) {
            if count >= 8 {
                self = KittyFlags()
                return
            }
            for _ in 0 ..< count {
                flags[index] = 0
                index = (index + 7) & 7
            }
        }

        mutating func set(_ value: UInt8, mode: UInt16) {
            switch mode {
            case 1: flags[index] = value & 0x1F
            case 2: flags[index] |= value & 0x1F
            case 3: flags[index] &= ~value & 0x1F
            default: break
            }
        }
    }

    var decModes: [UInt16: Bool] = [:]
    /// XTSAVE's record (`CSI ? Pm s`), for a later XTRESTORE.
    var savedDECModes: [UInt16: Bool] = [:]
    var alternateModeBits: [UInt16: Bool] = [:]
    var ansiModes: [UInt16: Bool] = [:]
    /// The mode number that set the mouse event or format last, 0 for
    /// none; nil while never touched.
    var mouseEvent: UInt16?
    var mouseFormat: UInt16?
    /// The last `CSI > … m` or `CSI > … n`, everything after the `[`.
    var modifyKeyFormat: [UInt8]?
    var cursorStyle: UInt16?
    var palette: [UInt16: [UInt8]] = [:]
    /// OSC 10–19 by index from 0; an empty value is a reset (OSC 110–119).
    var dynamicColors: [UInt16: [UInt8]] = [:]
    var title: [UInt8]?
    var workingDirectory: [UInt8]?
    var cursor = Cursor()
    var charsetsTouched = false
    /// The open OSC 8 link, as its `params;uri`.
    var hyperlink: [UInt8]?
    var hyperlinkTouched = false
    var scrollRegion: (top: UInt16, bottom: UInt16)?
    var scrollRegionTouched = false
    var isAlternateActive = false
    var alternateEntryMode: UInt16 = 1049
    var alternateEverUsed = false
    /// Per screen, primary first.
    var kitty = [KittyFlags(), KittyFlags()]
    var kittyTouched = [false, false]
    var savedCursor: [Cursor?] = [nil, nil]

    private var activeScreen: Int {
        isAlternateActive ? 1 : 0
    }

    // MARK: - Changes

    func decMode(_ mode: UInt16) -> Bool {
        if Self.alternateScreenModes.contains(mode) {
            return alternateModeBits[mode] ?? false
        }
        if Self.mouseEventModes.contains(mode) {
            return mouseEvent == mode
        }
        if Self.mouseFormatModes.contains(mode) {
            return mouseFormat == mode
        }
        return decModes[mode] ?? Self.defaultDECMode(mode)
    }

    mutating func setDECMode(_ mode: UInt16, _ enabled: Bool) {
        if Self.trackedDECModes.contains(mode) {
            decModes[mode] = enabled
            if mode == 6 {
                cursor.origin = enabled
            }
        } else if Self.mouseEventModes.contains(mode) {
            mouseEvent = enabled ? mode : 0
        } else if Self.mouseFormatModes.contains(mode) {
            mouseFormat = enabled ? mode : 0
        } else if Self.alternateScreenModes.contains(mode) {
            alternateModeBits[mode] = enabled
            switchScreen(mode: mode, enabled: enabled)
        } else if mode == 1048 {
            if enabled {
                saveCursor()
            } else {
                restoreCursor()
            }
        }
    }

    mutating func saveDECMode(_ mode: UInt16) {
        savedDECModes[mode] = decMode(mode)
    }

    mutating func restoreDECMode(_ mode: UInt16) {
        setDECMode(mode, savedDECModes[mode] ?? false)
    }

    mutating func setANSIMode(_ mode: UInt16, _ enabled: Bool) {
        guard Self.trackedANSIModes.contains(mode) else { return }
        ansiModes[mode] = enabled
    }

    /// `Terminal.switchScreenMode`: 1049 saves the cursor on the way in and
    /// restores it on the way out; every switch carries the charsets, copies
    /// the cursor's style across, and ends the hyperlink.
    private mutating func switchScreen(mode: UInt16, enabled: Bool) {
        if mode == 1049, enabled {
            saveCursor()
        }
        if enabled != isAlternateActive {
            hyperlink = nil
            isAlternateActive = enabled
        }
        if enabled {
            alternateEntryMode = mode
            alternateEverUsed = true
        } else if mode == 1049 {
            restoreCursor()
        }
    }

    mutating func saveCursor() {
        savedCursor[activeScreen] = cursor
    }

    mutating func restoreCursor() {
        let restored = savedCursor[activeScreen] ?? Cursor()
        cursor = restored
        if restored.origin || decModes[6] != nil {
            decModes[6] = restored.origin
        }
    }

    mutating func applySGR(_ parameters: [UInt8], isReset: Bool, startsWithReset: Bool) {
        if isReset {
            cursor.pen = []
        } else if startsWithReset {
            cursor.pen = [parameters]
        } else {
            cursor.pen.append(parameters)
            if cursor.pen.count > Self.maximumPenSequences {
                cursor.pen.removeFirst(cursor.pen.count - Self.maximumPenSequences)
            }
        }
    }

    mutating func designateCharset(slot: Int, final: UInt8) {
        guard slot >= 0, slot < 4 else { return }
        cursor.charsets.slots[slot] = final
        charsetsTouched = true
    }

    mutating func invokeCharset(gl: UInt8? = nil, gr: UInt8? = nil) {
        if let gl {
            cursor.charsets.gl = gl
        }
        if let gr {
            cursor.charsets.gr = gr
        }
        charsetsTouched = true
    }

    mutating func kittyPush(_ flags: UInt8) {
        kitty[activeScreen].push(flags)
        kittyTouched[activeScreen] = true
    }

    mutating func kittyPop(_ count: UInt16) {
        kitty[activeScreen].pop(count)
        kittyTouched[activeScreen] = true
    }

    mutating func kittySet(_ flags: UInt8, mode: UInt16) {
        kitty[activeScreen].set(flags, mode: mode)
        kittyTouched[activeScreen] = true
    }

    mutating func setScrollRegion(top: UInt16, bottom: UInt16) {
        scrollRegionTouched = true
        // Ghostty applies 0 and 1 for the top, and 0 for the bottom, as
        // the screen's edges; with the rows unknown here, a region that
        // starts at the top and names no bottom is the whole screen.
        if top <= 1, bottom == 0 {
            scrollRegion = nil
        } else {
            scrollRegion = (top, bottom)
        }
    }

    mutating func setHyperlink(_ value: [UInt8]?) {
        hyperlink = value
        hyperlinkTouched = true
    }

    /// DECSTR, as `Terminal.softReset` does it.
    mutating func softReset() {
        for mode: UInt16 in [25, 6, 7, 45, 1045, 1, 66, 69] where decModes[mode] != nil {
            decModes[mode] = Self.defaultDECMode(mode)
        }
        for mode: UInt16 in [4, 2] where ansiModes[mode] != nil {
            ansiModes[mode] = false
        }
        if scrollRegionTouched {
            scrollRegion = nil
        }
        cursor.pen = []
        cursor.origin = false
        cursor.charsets = Charsets()
        savedCursor[activeScreen] = nil
        if modifyKeyFormat != nil {
            modifyKeyFormat = Array(">m".utf8)
        }
        if cursorStyle != nil {
            cursorStyle = 0
        }
        palette = [:]
    }

    /// RIS, as `Terminal.fullReset` does it: everything back to its
    /// default, every touched setting still written out.
    mutating func fullReset() {
        for mode in decModes.keys {
            decModes[mode] = Self.defaultDECMode(mode)
        }
        for mode in ansiModes.keys {
            ansiModes[mode] = Self.defaultANSIMode(mode)
        }
        alternateModeBits = [:]
        savedDECModes = [:]
        if mouseEvent != nil {
            mouseEvent = 0
        }
        if mouseFormat != nil {
            mouseFormat = 0
        }
        if modifyKeyFormat != nil {
            modifyKeyFormat = Array(">m".utf8)
        }
        if cursorStyle != nil {
            cursorStyle = 0
        }
        palette = [:]
        if title != nil {
            title = []
        }
        workingDirectory = nil
        cursor = Cursor()
        hyperlink = nil
        if scrollRegionTouched {
            scrollRegion = nil
        }
        isAlternateActive = false
        kitty = [KittyFlags(), KittyFlags()]
        savedCursor = [nil, nil]
    }

    // MARK: - Writing it back

    /// This state, with every setting `later` touched that this one never
    /// did written out at its default. A replay is read by terminals that
    /// may have shown the session up to any point before its end, so its
    /// preamble has to put back everything the rest of it can find set.
    func includingSettings(touchedBy later: TerminalReplayState) -> TerminalReplayState {
        var state = self
        for mode in later.decModes.keys where state.decModes[mode] == nil {
            state.decModes[mode] = Self.defaultDECMode(mode)
        }
        for mode in later.savedDECModes.keys where state.savedDECModes[mode] == nil {
            state.savedDECModes[mode] = false
        }
        for mode in later.ansiModes.keys where state.ansiModes[mode] == nil {
            state.ansiModes[mode] = Self.defaultANSIMode(mode)
        }
        if state.mouseEvent == nil, later.mouseEvent != nil {
            state.mouseEvent = 0
        }
        if state.mouseFormat == nil, later.mouseFormat != nil {
            state.mouseFormat = 0
        }
        if state.modifyKeyFormat == nil, later.modifyKeyFormat != nil {
            state.modifyKeyFormat = Array(">m".utf8)
        }
        if state.cursorStyle == nil, later.cursorStyle != nil {
            state.cursorStyle = 0
        }
        for index in later.dynamicColors.keys where state.dynamicColors[index] == nil {
            state.dynamicColors[index] = []
        }
        if state.title == nil, later.title != nil {
            state.title = []
        }
        state.charsetsTouched = state.charsetsTouched || later.charsetsTouched
        state.hyperlinkTouched = state.hyperlinkTouched || later.hyperlinkTouched
        state.alternateEverUsed = state.alternateEverUsed || later.alternateEverUsed
        state.kittyTouched = [state.kittyTouched[0] || later.kittyTouched[0], state.kittyTouched[1] || later.kittyTouched[1]]
        return state
    }

    /// The sequences that put a terminal into this state, from wherever it
    /// stands: a fresh one, or one that already showed this session further
    /// along. Never anything a terminal answers.
    func preamble() -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(512)
        var writer = PreambleWriter()

        // Back to the primary screen of a terminal that is on the other,
        // then DECSTR for a baseline: it drops the pen, the charsets, the
        // saved cursor, the scroll region, the palette and the cursor style
        // a reused terminal may still hold, without clearing a thing.
        if alternateEverUsed {
            out += csi("?1049l")
        }
        out += csi("!p")
        out += csi("H")
        out += csi("2J")

        // The alternate screen keeps its own kitty flags and saved cursor
        // while it is not shown, and a program that enters it later finds
        // them there: visited to set them, DECSTR clearing what a reused
        // terminal left on it.
        if alternateEverUsed, !isAlternateActive {
            out += csi("?1047h")
            out += csi("!p")
            writer.charsetsReset()
            if kittyTouched[1] {
                out += kittyRebuild(kitty[1])
            }
            if let saved = savedCursor[1] {
                out += writer.cursorState(saved)
                out += [0x1B, 0x37]
            }
            out += csi("?1047l")
        }
        if kittyTouched[0] {
            out += kittyRebuild(kitty[0])
        }
        if isAlternateActive {
            if alternateEntryMode == 1049 {
                // 1049 saves the primary cursor as it switches: the cursor
                // it saved then is the primary's saved cursor now.
                out += writer.cursorState(savedCursor[0] ?? Cursor())
                out += csi("?1049h")
            } else {
                if let saved = savedCursor[0] {
                    out += writer.cursorState(saved)
                    out += [0x1B, 0x37]
                }
                out += csi("?\(alternateEntryMode)h")
                out += csi("H")
                out += csi("2J")
            }
            out += csi("!p")
            writer.charsetsReset()
            if kittyTouched[1] {
                out += kittyRebuild(kitty[1])
            }
            if let saved = savedCursor[1] {
                out += writer.cursorState(saved)
                out += [0x1B, 0x37]
            }
        } else if let saved = savedCursor[0] {
            out += writer.cursorState(saved)
            out += [0x1B, 0x37]
        }

        // XTSAVE's record first, each mode set to what was saved and saved
        // again; every mode's own value follows.
        for mode in savedDECModes.keys.sorted() where !Self.alternateScreenModes.contains(mode) && mode != 1048 {
            out += csi("?\(mode)\(savedDECModes[mode] == true ? "h" : "l")")
            out += csi("?\(mode)s")
        }
        for mode in decModes.keys.sorted() {
            out += csi("?\(mode)\(decModes[mode] == true ? "h" : "l")")
        }
        if let mouseEvent {
            out += mouseEvent == 0 ? csi("?1000l") : csi("?\(mouseEvent)h")
        }
        if let mouseFormat {
            out += mouseFormat == 0 ? csi("?1006l") : csi("?\(mouseFormat)h")
        }
        for mode in ansiModes.keys.sorted() {
            out += csi("\(mode)\(ansiModes[mode] == true ? "h" : "l")")
        }
        if let modifyKeyFormat {
            out += [0x1B, 0x5B] + modifyKeyFormat
        }
        if let cursorStyle {
            out += csi("\(cursorStyle) q")
        }
        for index in palette.keys.sorted() {
            if let value = palette[index] {
                out += osc(Array("4;\(index);".utf8) + value)
            }
        }
        for index in dynamicColors.keys.sorted() {
            guard let value = dynamicColors[index] else { continue }
            if value.isEmpty {
                out += osc(Array("\(110 + Int(index))".utf8))
            } else {
                out += osc(Array("\(10 + Int(index));".utf8) + value)
            }
        }
        if let title {
            out += osc(Array("2;".utf8) + title)
        }
        if let workingDirectory {
            out += osc(Array("7;".utf8) + workingDirectory)
        }

        out += writer.cursorState(cursor, charsetsTouched: charsetsTouched)
        if hyperlinkTouched {
            out += osc(Array("8;".utf8) + (hyperlink ?? Array(";".utf8)))
        }
        if let scrollRegion {
            out += csi(scrollRegion.bottom == 0 ? "\(scrollRegion.top)r" : "\(scrollRegion.top);\(scrollRegion.bottom)r")
        }
        out += csi("H")
        return out
    }

    /// Writes cursor states one after another, remembering which charset
    /// slots it left designated: Ghostty's initial UTF-8 set has no
    /// designation of its own, so a slot an earlier state changed is put
    /// back as ASCII, which prints the same.
    private struct PreambleWriter {
        private var designated: [Bool] = [false, false, false, false]

        mutating func charsetsReset() {
            designated = [false, false, false, false]
        }

        mutating func cursorState(_ cursor: Cursor, charsetsTouched: Bool = true) -> [UInt8] {
            var out = csi("0m")
            for parameters in cursor.pen {
                out += [0x1B, 0x5B] + parameters + [0x6D]
            }
            guard charsetsTouched || designated.contains(true) else { return out }
            let intermediates: [UInt8] = [0x28, 0x29, 0x2A, 0x2B]
            for slot in 0 ..< 4 {
                let value = cursor.charsets.slots[slot]
                if value != 0 {
                    out += [0x1B, intermediates[slot], value]
                    designated[slot] = true
                } else if designated[slot] {
                    out += [0x1B, intermediates[slot], 0x42]
                }
            }
            switch cursor.charsets.gl {
            case 1: out += [0x0E]
            case 2: out += [0x1B, 0x6E]
            case 3: out += [0x1B, 0x6F]
            default: out += [0x0F]
            }
            switch cursor.charsets.gr {
            case 1: out += [0x1B, 0x7E]
            case 3: out += [0x1B, 0x7C]
            default: out += [0x1B, 0x7D]
            }
            return out
        }
    }

    /// Rebuilds a kitty flag stack exactly: emptied, then the index walked
    /// to its place and every entry written. When nothing above the index
    /// is set (the usual stack), the base is set and the rest pushed.
    private func kittyRebuild(_ stack: KittyFlags) -> [UInt8] {
        var out = csi("<8u")
        let index = stack.index
        let aboveIndexIsClear = (index + 1 ..< 8).allSatisfy { stack.flags[$0] == 0 }
        if aboveIndexIsClear {
            if stack.flags[0] != 0 {
                out += csi("=\(stack.flags[0]);1u")
            }
            for slot in stride(from: 1, through: index, by: 1) {
                out += csi(">\(stack.flags[slot])u")
            }
        } else {
            for _ in 0 ..< index {
                out += csi(">0u")
            }
            for step in 1 ... 8 {
                out += csi(">\(stack.flags[(index + step) & 7])u")
            }
        }
        return out
    }
}

private func csi(_ body: String) -> [UInt8] {
    [0x1B, 0x5B] + Array(body.utf8)
}

private func osc(_ body: [UInt8]) -> [UInt8] {
    [0x1B, 0x5D] + body + [0x1B, 0x5C]
}
