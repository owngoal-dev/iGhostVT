//
//  ThemeListView.swift
//  iGhostVT
//

import GhosttyTheme
import SwiftUI

/// Which appearance slot a picked theme lands in.
enum ThemeSlot {
    case light
    case dark
}

struct ThemeListView: View {
    let slot: ThemeSlot
    @ObservedObject private var theme = AppTheme.shared
    @State private var searchText = ""

    private var themes: [GhosttyThemeDefinition] {
        let all = GhosttyThemeCatalog.allThemes
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        guard !searchText.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private var selectedName: String? {
        slot == .light ? theme.selection.lightName : theme.selection.darkName
    }

    var body: some View {
        List {
            ForEach(themes) { definition in
                Button(action: { select(definition) }) {
                    HStack(spacing: DS.Padding.m) {
                        swatch(for: definition, isSelected: definition.name == selectedName)
                        Text(definition.name)
                            .font(DS.Font.body)
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        Spacer(minLength: DS.Padding.s)
                        paletteStrip(for: definition)
                    }
                }
                .modifier(SeparatorFromRowEdge())
                .accessibilityAddTraits(definition.name == selectedName ? [.isSelected] : [])
            }
        }
        .searchable(text: $searchText)
        // A fixed inherited font makes the native search field taller.
        .font(nil)
        .navigationTitle(slot == .light ? "Light Theme" : "Dark Theme")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The theme's background and foreground; the selected theme's swatch
    /// is ringed in the accent and wears the checkmark, so no row spends a
    /// trailing column on a mark only one of them shows.
    private func swatch(for definition: GhosttyThemeDefinition, isSelected: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                .fill(Color(hex: definition.background))
                .frame(width: 34, height: 24)
                .overlay {
                    RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                        .strokeBorder(
                            isSelected ? Color.accentColor : Color.primary.opacity(0.15),
                            lineWidth: isSelected ? 2 : 1,
                        )
                }
            Text(verbatim: "$_")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(Color(hex: definition.foreground))
        }
        .overlay(alignment: .topTrailing) {
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .bold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.accentColor)
                    .offset(x: 5, y: -5)
            }
        }
        // The selection reaches VoiceOver as the row's `.isSelected` trait.
        .accessibilityHidden(true)
    }

    /// The eight base ANSI colors (0–7) as one segmented strip, so a theme's
    /// character shows without opening it. A missing entry falls back to the
    /// foreground rather than leaving a gap, so every strip has the same width.
    private func paletteStrip(for definition: GhosttyThemeDefinition) -> some View {
        HStack(spacing: 0) {
            ForEach(0 ..< 8, id: \.self) { index in
                Color(hex: definition.palette[index] ?? definition.foreground)
                    .frame(width: 7)
            }
        }
        .frame(height: 14)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }

    private func select(_ definition: GhosttyThemeDefinition) {
        switch slot {
        case .light:
            theme.selection.lightName = definition.name
        case .dark:
            theme.selection.darkName = definition.name
        }
    }
}

/// The separator spans the row's content, swatch to strip, instead of
/// starting at the name. iOS 15 has no guide to move and keeps its own.
private struct SeparatorFromRowEdge: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content.alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
        } else {
            content
        }
    }
}
