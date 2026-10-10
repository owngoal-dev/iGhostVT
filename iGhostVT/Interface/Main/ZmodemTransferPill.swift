//
//  ZmodemTransferPill.swift
//  iGhostVT
//

import SwiftUI

struct ZmodemTransferPill: View {
    let info: ZmodemTransferInfo
    var onCancel: () -> Void

    var body: some View {
        HStack(spacing: DS.Padding.m) {
            Image(systemName: iconName)
                .imageScale(.large)
                .foregroundStyle(iconTint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(displayName)
                    .font(DS.Font.labelEmphasis)
                    .lineLimit(1)
                    .truncationMode(.middle)
                caption
            }
            .frame(width: 220, alignment: .leading)
            if info.phase == .active {
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .imageScale(.large)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Cancel Transfer"))
            }
        }
        .padding(.horizontal, DS.Padding.l)
        .padding(.vertical, DS.Padding.m)
        .barGlass(in: Capsule(), interactive: info.phase == .active)
    }

    @ViewBuilder
    private var caption: some View {
        switch info.phase {
        case .active:
            if info.isWaitingForConnection {
                Text("Waiting for connection…")
                    .font(DS.Font.detail)
                    .foregroundStyle(.secondary)
            } else if let fraction {
                // Figures arrive at most ten times a second, and in bursts
                // seconds apart over a slow link: glide between them rather
                // than jump.
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .animation(.easeOut(duration: 0.3), value: fraction)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }
        case .done:
            Text(info.direction == .download ? String(localized: "Saved") : String(localized: "Sent"))
                .font(DS.Font.detail)
                .foregroundStyle(.secondary)
        case .cancelled:
            Text("Cancelled")
                .font(DS.Font.detail)
                .foregroundStyle(.secondary)
        case let .failed(reason):
            Text(verbatim: reason)
                .font(DS.Font.detail)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private var displayName: String {
        info.name.isEmpty ? String(localized: "File") : info.name
    }

    private var iconName: String {
        switch info.phase {
        case .active: info.direction == .download ? "arrow.down.circle" : "arrow.up.circle"
        case .done: "checkmark.circle.fill"
        case .cancelled: "xmark.circle"
        case .failed: "exclamationmark.circle.fill"
        }
    }

    private var iconTint: Color {
        switch info.phase {
        case .active: .primary
        case .done: .green
        case .cancelled: .secondary
        case .failed: .orange
        }
    }

    private var fraction: Double? {
        guard let total = info.total, total > 0 else { return nil }
        return min(1, Double(info.transferred) / Double(total))
    }
}
