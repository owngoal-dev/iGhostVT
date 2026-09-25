import GhosttyTerminal
import SwiftUI

/// The question Ghostty asks before a protected clipboard operation: a
/// program reading the clipboard (OSC 52, `clipboard-read = ask`), a
/// program changing it when writes are set to ask, or a paste that paste
/// protection flagged — line breaks going to a program without bracketed
/// paste, which would run them as commands. Without an answer libghostty
/// denies a program's request silently, which is how a tool's "paste from
/// clipboard" used to do nothing at all.
///
/// The requests queue on the `TabManager`, which installs every tab's hook
/// so none is missed; the head of the queue is the one on screen.
@MainActor
enum ClipboardConfirmation {
    static func alert(
        for request: TerminalClipboardConfirmationRequest,
        finish: @escaping () -> Void,
    ) -> AlertViewController {
        AlertViewController(
            title: title(for: request.kind),
            message: message(for: request),
            actions: [
                AlertAction("Deny") {
                    request.respond(allow: false)
                    finish()
                },
                AlertAction("Allow", kind: .accent) {
                    request.respond(allow: true)
                    finish()
                },
            ],
        )
    }

    private static func title(for kind: TerminalClipboardRequestKind) -> String.LocalizationValue {
        switch kind {
        case .osc52Read: "Allow Clipboard Access?"
        case .osc52Write: "Allow Clipboard Change?"
        case .paste: "Paste Unsafe Text?"
        }
    }

    private static func message(for request: TerminalClipboardConfirmationRequest) -> String.LocalizationValue {
        let preview = preview(of: request.contents)
        switch request.kind {
        case .osc52Read:
            return "A program in this terminal wants to read the clipboard: \(preview)"
        case .osc52Write:
            return "A program in this terminal wants to replace the clipboard with: \(preview)"
        case .paste:
            return "This text contains line breaks or hidden characters that the program may run as commands: \(preview)"
        }
    }

    /// The first line or so of what is at stake, short enough for a card.
    /// Sliced before it is flattened: a paste can be large, and this runs on
    /// the main thread as the alert appears.
    private static func preview(of contents: String) -> String {
        let limit = 120
        let head = contents.prefix(limit + 1)
        let flattened = head.prefix(limit)
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .joined(separator: " ⏎ ")
        return head.count > limit ? "“\(flattened)…”" : "“\(flattened)”"
    }
}

extension View {
    func clipboardConfirmation(_ tabManager: TabManager) -> some View {
        modifier(WindowAlertPresenter(
            requests: tabManager.$clipboardRequests.map(\.first),
            onFinish: { tabManager.finishClipboardRequest() },
            makeAlert: ClipboardConfirmation.alert,
        ))
    }
}
