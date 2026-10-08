//
//  AccentColorPicker.swift
//  iGhostVT
//

import SwiftUI

/// One round swatch per colour, the app's own accent first, the chosen one
/// ringed. Scrollable touch targets on iOS; a compact row on the Mac.
struct AccentColorPicker: View {
    @AppStorage(AccentColorPreference.key) private var rawValue = AccentColorPreference.appDefault.rawValue

    #if targetEnvironment(macCatalyst)
        private static let side: CGFloat = 20
    #else
        private static let side: CGFloat = 28
        private static let touchTargetSide: CGFloat = 44
    #endif
    private static let ring: CGFloat = 2
    private static let gap: CGFloat = 2
    /// The Mac row's width at its own 10pt spacing.
    private static let preferredWidth: CGFloat = {
        let count = CGFloat(AccentColorPreference.allCases.count)
        return count * side + 2 * (ring + gap) + (count - 1) * 10
    }()

    private var selection: AccentColorPreference {
        AccentColorPreference(rawValue: rawValue) ?? .appDefault
    }

    var body: some View {
        Group {
            #if targetEnvironment(macCatalyst)
                HStack(spacing: 0) {
                    ForEach(Array(AccentColorPreference.allCases.enumerated()), id: \.element) { index, choice in
                        if index > 0 {
                            Spacer(minLength: 0)
                        }
                        swatch(choice)
                    }
                }
                .frame(maxWidth: Self.preferredWidth)
            #else
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(AccentColorPreference.allCases) { choice in
                            swatch(choice)
                        }
                    }
                    .padding(.horizontal, DS.Padding.m)
                }
                .frame(height: Self.touchTargetSide)
                .frame(maxWidth: .infinity, alignment: .leading)
            #endif
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: rawValue)
    }

    private func swatch(_ choice: AccentColorPreference) -> some View {
        let isSelected = choice == selection
        return Button {
            rawValue = choice.rawValue
        } label: {
            fill(for: choice)
                .frame(width: Self.side, height: Self.side)
                .overlay {
                    Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5)
                }
                .padding(isSelected ? Self.ring + Self.gap : 0)
                .overlay {
                    Circle()
                        .strokeBorder(ringColor(for: choice), lineWidth: Self.ring)
                        .opacity(isSelected ? 1 : 0)
                }
            #if targetEnvironment(macCatalyst)
                .contentShape(Circle())
            #else
                // Reserve every touch target before selection so its centre never moves.
                .frame(width: Self.touchTargetSide, height: Self.touchTargetSide)
                .contentShape(Rectangle())
            #endif
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: choice.title))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func fill(for choice: AccentColorPreference) -> some View {
        Circle().fill(choice.color)
    }

    private func ringColor(for choice: AccentColorPreference) -> Color {
        choice.color
    }
}
