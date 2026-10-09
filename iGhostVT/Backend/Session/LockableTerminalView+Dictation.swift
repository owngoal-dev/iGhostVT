//
//  LockableTerminalView+Dictation.swift
//  iGhostVT
//

import GhosttyTerminal
import UIKit

// Dictation streams. It types its first guess at once and then revises it
// as the person keeps talking — "你", then "你好", then "你好世界" — and to
// revise it, UIKit reads the guess back out of the text view, finds where
// it sits before the caret, and replaces that range. A terminal's text
// document is only ever the IME composition, empty once text is typed, so
// UIKit found nothing to replace and gave up after the first guess: the
// shell got one character and the rest of the sentence went nowhere.
//
// So while dictation types, the view keeps what it typed as a document of
// its own (`DictatedText`) and answers UIKit's questions from it. A revision
// becomes what a person at the shell would do — Delete for every character
// that changed, then the new ending — so the shell's line always says what
// the guess says. Only dictation does this: ordinary typing never fills the
// document, so the keyboard sees no context and behaves as it always did
// (no double-space period, no held Delete stopping early). The text is
// let go the moment anything else edits the line — a key, a tap, Return,
// marked text, the keyboard going away — because from then on the shell's
// line is no longer what the document would say.

/// What dictation has typed and may still revise. Offsets are UTF-16, as
/// UIKit counts them. The document is one empty anchor position (the
/// library's: it keeps the caret off the start of the document, where
/// UIKit stops a held Delete) followed by the text.
struct DictatedText {
    var text = ""
    /// Within `text`. UIKit may select the guess before replacing it.
    var selection = NSRange(location: 0, length: 0)

    var isEmpty: Bool {
        text.isEmpty
    }

    var length: Int {
        (text as NSString).length
    }

    /// The whole document: the anchor and the text.
    var documentLength: Int {
        1 + length
    }

    /// Longer than any one utterance; past it the oldest text is dropped,
    /// which only costs a revision reaching that far back.
    static let maximumLength = 2048
}

/// A position in the dictated document.
final class DictatedTextPosition: UITextPosition {
    let index: Int

    init(_ index: Int) {
        self.index = index
    }
}

final class DictatedTextRange: UITextRange {
    let lower: Int
    let upper: Int

    init(_ from: Int, _ to: Int) {
        lower = min(from, to)
        upper = max(from, to)
    }

    override var start: UITextPosition {
        DictatedTextPosition(lower)
    }

    override var end: UITextPosition {
        DictatedTextPosition(upper)
    }

    override var isEmpty: Bool {
        lower == upper
    }
}

extension LockableTerminalView {
    /// Whether the system is taking dictation into this app right now.
    /// UIKit says so only privately; without the answer the view behaves as
    /// it did before, one guess and no more. Never on the Mac, whose
    /// dictation is AppKit's and is left as it was.
    private static var isDictationRunning: Bool {
        #if targetEnvironment(macCatalyst)
            return false
        #else
            guard let controller = NSClassFromString("UIDictationController") as AnyObject? else { return false }
            let selector = NSSelectorFromString("isRunning")
            guard controller.responds(to: selector),
                  let method = controller.method(for: selector)
            else { return false }
            typealias IsRunning = @convention(c) (AnyObject, Selector) -> Bool
            return unsafeBitCast(method, to: IsRunning.self)(controller, selector)
        #endif
    }

    /// Holding dictated text, with no composition in progress.
    private var holdsDictatedText: Bool {
        !dictatedText.isEmpty && super.markedTextRange == nil
    }

    /// Lets go of the dictated text: the shell's line has moved on.
    func releaseDictatedText() {
        guard !dictatedText.isEmpty else { return }
        inputDelegate?.selectionWillChange(self)
        inputDelegate?.textWillChange(self)
        dictatedText = DictatedText()
        inputDelegate?.textDidChange(self)
        inputDelegate?.selectionDidChange(self)
    }

    // MARK: - Editing

    override func insertText(_ text: String) {
        guard Self.isDictationRunning || holdsDictatedText,
              super.markedTextRange == nil,
              !text.isEmpty,
              !text.contains(where: \.isNewline)
        else {
            releaseDictatedText()
            super.insertText(text)
            return
        }
        replaceDictated(dictatedText.selection, with: text)
    }

    override func replace(_ range: UITextRange, withText text: String) {
        guard holdsDictatedText else {
            releaseDictatedText()
            super.replace(range, withText: text)
            return
        }
        replaceDictated(dictatedRange(range), with: text)
    }

    override func deleteBackward() {
        guard holdsDictatedText else {
            releaseDictatedText()
            super.deleteBackward()
            return
        }
        var range = dictatedText.selection
        if range.length == 0 {
            // One character back from the caret, as the keyboard counts it.
            let caret = range.location
            guard caret > 0 else {
                releaseDictatedText()
                super.deleteBackward()
                return
            }
            let composed = (dictatedText.text as NSString).rangeOfComposedCharacterSequence(at: caret - 1)
            range = NSRange(location: composed.location, length: caret - composed.location)
        }
        replaceDictated(range, with: "")
    }

    override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        releaseDictatedText()
        super.setMarkedText(markedText, selectedRange: selectedRange)
    }

    /// Replaces `range` of the dictated text, in the document and on the
    /// shell's line. The shell can only be edited at its end, so a range
    /// that stops short of the end is widened to it and the text after it
    /// is typed again. What the old and new text share at the start is
    /// left alone — a guess that only grew types only its new end.
    private func replaceDictated(_ range: NSRange, with replacement: String) {
        let current = dictatedText.text as NSString
        let start = min(max(range.location, 0), current.length)
        let end = min(max(range.location + range.length, start), current.length)
        let old = current.substring(from: start)
        let new = replacement + current.substring(from: end)

        let shared = old.commonPrefix(with: new)
        let deleted = old.dropFirst(shared.count)
        let typed = String(new.dropFirst(shared.count))

        var text = current.substring(to: start) + new
        let overflow = (text as NSString).length - DictatedText.maximumLength
        if overflow > 0 {
            let cut = (text as NSString).rangeOfComposedCharacterSequence(at: overflow)
            text = (text as NSString).substring(from: cut.location)
        }

        // The document changes first: the library tells UIKit about each
        // key it sends, and UIKit reads the document back when it hears.
        // The caret goes to the end, where the shell's cursor will be.
        inputDelegate?.selectionWillChange(self)
        inputDelegate?.textWillChange(self)
        let length = (text as NSString).length
        dictatedText = DictatedText(text: text, selection: NSRange(location: length, length: 0))
        inputDelegate?.textDidChange(self)
        inputDelegate?.selectionDidChange(self)

        // A line editor's Delete takes one character — one scalar for zsh
        // and readline alike — off the end.
        for _ in deleted.unicodeScalars {
            super.deleteBackward()
        }
        if !typed.isEmpty {
            super.insertText(typed)
        }
    }

    // MARK: - The document UIKit reads

    /// `range` as offsets into the dictated text.
    private func dictatedRange(_ range: UITextRange) -> NSRange {
        let lower = textIndex(of: range.start)
        let upper = textIndex(of: range.end)
        return NSRange(location: min(lower, upper), length: abs(upper - lower))
    }

    /// A document position as an offset into the dictated text; the anchor
    /// reads as its start.
    private func textIndex(of position: UITextPosition) -> Int {
        max(documentIndex(of: position) - 1, 0)
    }

    /// A position the library handed out before the text was held is the
    /// anchor or the caret it had then, which is the end now.
    private func documentIndex(of position: UITextPosition) -> Int {
        if let position = position as? DictatedTextPosition {
            return min(max(position.index, 0), dictatedText.documentLength)
        }
        return super.offset(from: super.beginningOfDocument, to: position) <= 0 ? 0 : dictatedText.documentLength
    }

    override var selectedTextRange: UITextRange? {
        get {
            guard holdsDictatedText else { return super.selectedTextRange }
            let selection = dictatedText.selection
            return DictatedTextRange(1 + selection.location, 1 + selection.location + selection.length)
        }
        set {
            guard holdsDictatedText else {
                super.selectedTextRange = newValue
                return
            }
            guard let newValue else { return }
            dictatedText.selection = dictatedRange(newValue)
        }
    }

    override var beginningOfDocument: UITextPosition {
        holdsDictatedText ? DictatedTextPosition(0) : super.beginningOfDocument
    }

    override var endOfDocument: UITextPosition {
        holdsDictatedText ? DictatedTextPosition(dictatedText.documentLength) : super.endOfDocument
    }

    override func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
        guard holdsDictatedText else { return super.textRange(from: fromPosition, to: toPosition) }
        return DictatedTextRange(documentIndex(of: fromPosition), documentIndex(of: toPosition))
    }

    override func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
        guard holdsDictatedText else { return super.position(from: position, offset: offset) }
        let index = documentIndex(of: position) + offset
        guard index >= 0, index <= dictatedText.documentLength else { return nil }
        return DictatedTextPosition(index)
    }

    override func position(
        from position: UITextPosition,
        in direction: UITextLayoutDirection,
        offset: Int,
    ) -> UITextPosition? {
        guard holdsDictatedText else { return super.position(from: position, in: direction, offset: offset) }
        switch direction {
        case .left, .up: return self.position(from: position, offset: -offset)
        default: return self.position(from: position, offset: offset)
        }
    }

    override func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
        guard holdsDictatedText else { return super.compare(position, to: other) }
        let lhs = documentIndex(of: position)
        let rhs = documentIndex(of: other)
        return lhs < rhs ? .orderedAscending : lhs > rhs ? .orderedDescending : .orderedSame
    }

    override func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int {
        guard holdsDictatedText else { return super.offset(from: from, to: toPosition) }
        return documentIndex(of: toPosition) - documentIndex(of: from)
    }

    override func text(in range: UITextRange) -> String? {
        guard holdsDictatedText else { return super.text(in: range) }
        return (dictatedText.text as NSString).substring(with: dictatedRange(range))
    }

    override func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
        guard holdsDictatedText else { return super.position(within: range, farthestIn: direction) }
        switch direction {
        case .left, .up: return range.start
        default: return range.end
        }
    }

    override func characterRange(
        byExtending position: UITextPosition,
        in direction: UITextLayoutDirection,
    ) -> UITextRange? {
        guard holdsDictatedText else { return super.characterRange(byExtending: position, in: direction) }
        let index = documentIndex(of: position)
        switch direction {
        case .left, .up: return DictatedTextRange(max(index - 1, 0), index)
        default: return DictatedTextRange(index, min(index + 1, dictatedText.documentLength))
        }
    }

    // The text is already on the shell's line, under the terminal's own
    // cursor; every rect UIKit asks for is that cursor's.

    override func caretRect(for position: UITextPosition) -> CGRect {
        holdsDictatedText ? super.caretRect(for: super.endOfDocument) : super.caretRect(for: position)
    }

    override func firstRect(for range: UITextRange) -> CGRect {
        holdsDictatedText ? super.caretRect(for: super.endOfDocument) : super.firstRect(for: range)
    }

    override func closestPosition(to point: CGPoint) -> UITextPosition? {
        holdsDictatedText ? endOfDocument : super.closestPosition(to: point)
    }

    override func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? {
        holdsDictatedText ? range.end : super.closestPosition(to: point, within: range)
    }

    override func characterRange(at point: CGPoint) -> UITextRange? {
        holdsDictatedText
            ? DictatedTextRange(dictatedText.documentLength, dictatedText.documentLength)
            : super.characterRange(at: point)
    }

    // MARK: - Anything else that edits the line

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        releaseDictatedText()
        super.touchesBegan(touches, with: event)
    }

    @discardableResult
    override func resignFirstResponder() -> Bool {
        releaseDictatedText()
        return super.resignFirstResponder()
    }
}
