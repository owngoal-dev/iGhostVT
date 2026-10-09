//
//  LockScreenView.swift
//  iGhostVTWidgets
//

import SwiftUI
import WidgetKit

/// The lock screen card: one header line — the ghost, the name, and the
/// counts in a single phrase — and a row per session saying what it is
/// running and where. A card that only counted spent its height on a big
/// number and a status bar that, with one session, was always full.
///
/// Rendered on the lock screen only; the island has its own trimmed rendition.
struct LockScreenView: View {
    @Environment(\.colorScheme) private var colorScheme

    let state: TerminalSessionAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.line) {
            SummaryHeader(state: state, glyphSize: 22)
            if let remote = state.remoteAccess {
                RemoteAccessLine(remote: remote)
            }
            SessionRows(state: state, limit: Self.rowLimit)
        }
        .padding(Spacing.card)
        .fontDesign(.rounded)
        .animation(.easeInOut(duration: 0.35), value: state)
        .activityBackgroundTint(colorScheme == .dark ? .black : .white)
        .activitySystemActionForegroundColor(Palette.accent)
    }

    /// The lock screen's card keeps to about the height the old one had.
    private static let rowLimit = 3
}

/// The ghost, the name, and the counts phrase trailing in the dim style.
struct SummaryHeader: View {
    let state: TerminalSessionAttributes.ContentState
    let glyphSize: CGFloat

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.line) {
            Image("GhostGlyph")
                .resizable()
                .scaledToFit()
                .frame(width: glyphSize, height: glyphSize)
                .accessibilityHidden(true)
            Text(verbatim: AppName.text)
                .font(.subheadline.weight(.bold))
            Spacer(minLength: Spacing.line)
            if let summary = state.summaryLine {
                Text(summary)
                    .font(.subheadline)
                    .opacity(0.6)
                    .lineLimit(1)
                    .contentTransition(.numericText())
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Remote access is on: what this device is called to the others, and who
/// is connected — the reason the activity is up with no session at all.
struct RemoteAccessLine: View {
    let remote: TerminalSessionAttributes.RemoteAccess

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.line) {
            Image(systemName: remote.isPairing ? "qrcode" : "network")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Palette.accent)
                .frame(width: 8 + Spacing.line - 4, alignment: .leading)
                .accessibilityHidden(true)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: Spacing.line)
            Text(detail)
                .font(.footnote)
                .opacity(0.6)
                .lineLimit(1)
                .contentTransition(.numericText())
        }
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        remote.isPairing
            ? String(localized: "Pairing a device", comment: "Live Activity: a pairing window is open")
            : String(localized: "Remote access on", comment: "Live Activity: other devices can open terminals here")
    }

    private var detail: String {
        if remote.connectedCount > 0 {
            return String(
                localized: "\(remote.connectedCount) connected",
                comment: "Live Activity: paired devices connected right now",
            )
        }
        return remote.hostName
    }
}

/// One line per listed session — its status dot, the program in front, and
/// the directory — then how many more there are past the last row.
struct SessionRows: View {
    let state: TerminalSessionAttributes.ContentState
    let limit: Int

    var body: some View {
        let shown = Array(state.sessions.prefix(limit))
        let hidden = state.totalCount - shown.count
        VStack(alignment: .leading, spacing: Spacing.row) {
            ForEach(shown) { session in
                SessionRow(session: session)
            }
            if hidden > 0 {
                Text("+\(hidden) more")
                    .font(.footnote)
                    .opacity(0.5)
                    .padding(.leading, SessionRow.dotColumn)
            }
        }
    }
}

private struct SessionRow: View {
    let session: TerminalSessionAttributes.Session

    /// The dot and its gap, so the "more" line can start where names do.
    static let dotColumn: CGFloat = 8 + Spacing.line

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.line) {
            Circle()
                .fill(session.status.color)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            // Every name at one weight: a bold one read as a heading, not
            // as the tab in front.
            Text(verbatim: session.name)
                .font(.subheadline)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: Spacing.line)
            if !session.directory.isEmpty {
                Text(verbatim: session.directory)
                    .font(.footnote.monospaced())
                    .opacity(0.5)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(session.isActive ? .isSelected : [])
    }
}

extension TerminalSessionAttributes.Session {
    /// The program in front first — it is the daemon's short, stable name
    /// — then whatever the shell titled itself, then the configured shell,
    /// then the session's number.
    var name: String {
        if let process, !process.isEmpty {
            return process
        }
        if !title.isEmpty {
            return title
        }
        if !shell.isEmpty {
            return shell
        }
        if let number {
            return String(localized: "Session \(number)", comment: "A session the widget has no other name for")
        }
        return "—"
    }
}

extension TerminalSessionAttributes.Session.Status {
    var color: Color {
        switch self {
        case .live: Palette.accent
        case .starting: Palette.starting
        case .failed: Palette.failed
        }
    }
}

/// What the card and the island derive from the payload. The counts
/// describe the listed sessions — the payload carries no status for
/// overflowed or detached ones.
extension TerminalSessionAttributes.ContentState {
    var liveCount: Int {
        sessions.filter { $0.status == .live }.count
    }

    var startingCount: Int {
        sessions.filter { $0.status == .starting }.count
    }

    var failedCount: Int {
        sessions.filter { $0.status == .failed }.count
    }

    /// "5 live · 1 starting · 1 detached", skipping empty groups; nil when
    /// there is nothing at all.
    var summaryLine: String? {
        var parts: [String] = []
        if liveCount > 0 {
            parts.append(String(localized: "\(liveCount) live", comment: "Sessions with a running shell"))
        }
        if startingCount > 0 {
            parts.append(String(localized: "\(startingCount) starting", comment: "Sessions still spawning"))
        }
        if failedCount > 0 {
            parts.append(String(localized: "\(failedCount) failed", comment: "Sessions whose transport gave up"))
        }
        if detachedCount > 0 {
            parts.append(String(
                localized: "\(detachedCount) detached",
                comment: "Sessions running with no tab attached",
            ))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Previews

#if DEBUG

    extension TerminalSessionAttributes {
        static let preview = TerminalSessionAttributes()
    }

    extension TerminalSessionAttributes.ContentState {
        /// The common case: a couple of tabs, one frontmost.
        static let typical = TerminalSessionAttributes.ContentState(
            sessions: [
                .init(
                    id: "a",
                    title: "make deb",
                    directory: "~/Documents/GitHub/iGhostVT",
                    shell: "zsh",
                    process: "make",
                    number: 1,
                    status: .live,
                    isActive: true,
                ),
                .init(
                    id: "b",
                    title: "",
                    directory: "~",
                    shell: "fish",
                    process: "fish",
                    number: 2,
                    status: .live,
                    isActive: false,
                ),
            ],
            overflowCount: 0,
            detachedCount: 0,
        )

        /// `typical`, a moment later — the same two sessions, a third one
        /// opening and one failed, more of them past the row cap. The overlap
        /// lets the canvas demonstrate the transition: the counts roll and
        /// the rows reorder.
        static let crowded = TerminalSessionAttributes.ContentState(
            sessions: [
                .init(
                    id: "a",
                    title: "make deb",
                    directory: "~/Documents/GitHub/iGhostVT",
                    shell: "zsh",
                    process: "make",
                    number: 1,
                    status: .live,
                    isActive: false,
                ),
                .init(
                    id: "b",
                    title: "",
                    directory: "~",
                    shell: "fish",
                    process: "fish",
                    number: 2,
                    status: .failed,
                    isActive: false,
                ),
                .init(
                    id: "c",
                    title: "ssh build-host",
                    directory: "",
                    shell: "zsh",
                    process: "ssh",
                    number: 3,
                    status: .starting,
                    isActive: true,
                ),
            ],
            overflowCount: 2,
            detachedCount: 1,
        )
    }

    /// Same iOS 17.0 scope as the island previews — see
    /// TerminalSessionActivityWidget.swift.
    @available(iOS 17.0, *)
    private enum LockScreenPreviews {
        #Preview("Lock Screen", as: .content, using: TerminalSessionAttributes.preview) {
            TerminalSessionActivityWidget()
        } contentStates: {
            TerminalSessionAttributes.ContentState.typical
            TerminalSessionAttributes.ContentState.crowded
        }
    }

#endif
