//
//  TerminalSessionActivityWidget.swift
//  iGhostVTWidgets
//

import ActivityKit
import SwiftUI
import WidgetKit

/// Dynamic Island + Lock Screen presentation of the running terminal
/// sessions. Expanded, the island shows a trimmed rendition of the lock
/// screen's card; closed, it wears the bare ghost with the count
/// in the status ring — the ghost alone when minimal.
struct TerminalSessionActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TerminalSessionAttributes.self) { context in
            LockScreenView(state: context.state)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    // Same inset as IslandSummary's, so the name sits flush
                    // over the number below it.
                    Text(verbatim: AppName.text)
                        .font(.subheadline.weight(.bold))
                        .fontDesign(.rounded)
                        .padding(.leading, Spacing.line)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Image("GhostGlyph")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 22, height: 22)
                        .padding(.trailing, Spacing.line)
                        .accessibilityHidden(true)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    IslandSummary(state: context.state)
                }
            } compactLeading: {
                Image("GhostGlyph")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 20, height: 20)
                    .frame(width: 24, alignment: .leading)
                    .accessibilityLabel(Text(verbatim: AppName.text))
            } compactTrailing: {
                // Up for remote access alone: the network glyph, not a 0.
                if context.state.totalCount == 0, context.state.remoteAccess != nil {
                    Image(systemName: "network")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Palette.accent)
                        .frame(width: 24, alignment: .trailing)
                        .accessibilityLabel("Remote access on")
                } else {
                    Text("\(context.state.totalCount)")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .contentTransition(.numericText())
                        .frame(width: 24, alignment: .trailing)
                }
            } minimal: {
                Image("GhostGlyph")
                    .resizable()
                    .scaledToFit()
                    .accessibilityLabel(Text(verbatim: AppName.text))
            }
        }
    }
}

/// The lock screen card cut down to what the expanded island's height and
/// corner radii leave room for: the counts phrase and the first two
/// sessions. The name and the ghost sit in the regions above.
private struct IslandSummary: View {
    let state: TerminalSessionAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.line) {
            if let summary = state.summaryLine {
                Text(summary)
                    .font(.subheadline)
                    .opacity(0.6)
                    .lineLimit(1)
                    .contentTransition(.numericText())
            }
            if let remote = state.remoteAccess {
                RemoteAccessLine(remote: remote)
            }
            SessionRows(state: state, limit: state.remoteAccess == nil ? 2 : 1)
        }
        .padding(Spacing.line)
        .fontDesign(.rounded)
        .animation(.easeInOut(duration: 0.35), value: state)
    }
}

#if DEBUG

    /// The Live Activity `#Preview` and its `PreviewActivityBuilder` are iOS
    /// 17.0 API, and the extension deploys to 16.2. A freestanding macro takes
    /// no `@available`, so the previews sit inside a scope that carries it —
    /// Xcode 27's compiler checks the builder's availability at the call site,
    /// where Xcode 26 did not.
    @available(iOS 17.0, *)
    private enum IslandPreviews {
        #Preview("Island Expanded", as: .dynamicIsland(.expanded), using: TerminalSessionAttributes.preview) {
            TerminalSessionActivityWidget()
        } contentStates: {
            TerminalSessionAttributes.ContentState.typical
            TerminalSessionAttributes.ContentState.crowded
        }

        #Preview("Island Compact", as: .dynamicIsland(.compact), using: TerminalSessionAttributes.preview) {
            TerminalSessionActivityWidget()
        } contentStates: {
            TerminalSessionAttributes.ContentState.typical
            TerminalSessionAttributes.ContentState.crowded
        }

        #Preview("Island Minimal", as: .dynamicIsland(.minimal), using: TerminalSessionAttributes.preview) {
            TerminalSessionActivityWidget()
        } contentStates: {
            TerminalSessionAttributes.ContentState.typical
            TerminalSessionAttributes.ContentState.crowded
        }
    }

#endif
