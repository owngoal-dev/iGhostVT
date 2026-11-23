//
//  MacSettingsControls.swift
//  iGhostVT
//

import SwiftUI

#if targetEnvironment(macCatalyst)

    // The pieces the Mac's settings window is laid out with, drawn the way
    // a Mac settings pane draws them — a label column on the leading side,
    // the controls beside it, checkboxes rather than switches, popup buttons
    // rather than disclosure rows. The app runs in the iPad idiom, so none
    // of these come from the system: SwiftUI's own Toggle is a switch here
    // and a Menu is a bare button.

    /// One row of a pane: the label, trailing-aligned in a column every row
    /// of the pane shares, centred on the row's one control beside it; the
    /// details — notes, secondary controls — stacked under the control, in
    /// its column. Centring on the control rather than on a baseline is what
    /// lines a label up with a stepper or a popup button, which have none.
    struct MacSettingsRow<Control: View, Details: View>: View {
        let label: LocalizedStringKey
        let labelWidth: CGFloat
        @ViewBuilder let control: () -> Control
        @ViewBuilder let details: () -> Details

        /// `labelWidth` is narrower in a sheet, which can be no wider than
        /// the settings window it hangs from.
        init(
            _ label: LocalizedStringKey,
            labelWidth: CGFloat = Self.paneLabelWidth,
            @ViewBuilder control: @escaping () -> Control,
            @ViewBuilder details: @escaping () -> Details,
        ) {
            self.label = label
            self.labelWidth = labelWidth
            self.control = control
            self.details = details
        }

        /// Wide enough for the longest label in any language the app
        /// ships; a longer one wraps rather than pushing the controls.
        static var paneLabelWidth: CGFloat {
            150
        }

        static var spacing: CGFloat {
            DS.Padding.m
        }

        var body: some View {
            VStack(alignment: .leading, spacing: DS.Padding.s) {
                HStack(alignment: .center, spacing: Self.spacing) {
                    Text(label)
                        .multilineTextAlignment(.trailing)
                        .frame(width: labelWidth, alignment: .trailing)
                    control()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: DS.Padding.s) {
                    details()
                }
                .padding(.leading, labelWidth + Self.spacing)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    extension MacSettingsRow where Details == EmptyView {
        init(
            _ label: LocalizedStringKey,
            labelWidth: CGFloat = Self.paneLabelWidth,
            @ViewBuilder control: @escaping () -> Control,
        ) {
            self.init(label, labelWidth: labelWidth, control: control, details: { EmptyView() })
        }
    }

    /// The dim explanation under a row's controls.
    struct MacSettingsNote: View {
        let text: LocalizedStringKey

        init(_ text: LocalizedStringKey) {
            self.text = text
        }

        var body: some View {
            Text(text)
                .font(DS.Font.detail)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A small round glyph button set after a line of text, the text's own
    /// size and on its baseline (the caller's `HStack` aligns them).
    struct MacInlineIconButton: View {
        let symbol: String
        let label: LocalizedStringKey
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                Image(systemName: symbol)
                    .foregroundColor(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(label)
        }
    }

    extension View {
        /// The sheet as big as its content: a plain sheet on the Mac is a
        /// fixed form sheet much larger than a short list.
        @ViewBuilder
        func fittedSheet() -> some View {
            if #available(macCatalyst 18.0, *) {
                presentationSizing(.fitted)
            } else {
                self
            }
        }
    }

    /// A pane's body: rows top to bottom at the pane's margins, groups of
    /// rows parted by `Divider`s.
    struct MacSettingsForm<Content: View>: View {
        @ViewBuilder let content: () -> Content

        var body: some View {
            VStack(alignment: .leading, spacing: DS.Padding.l) {
                content()
            }
            .padding(.horizontal, DS.Padding.xl)
            .padding(.vertical, DS.Padding.xl)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    /// A checkbox drawn the way AppKit draws one — a small rounded square,
    /// white with a hairline edge and a faint shadow when off, the accent
    /// with a white tick when on — and its title, one click target. The
    /// system's own is out of reach: `UISwitch`'s checkbox style exists only
    /// in the Mac idiom, and in the iPad idiom this app runs in, UIKit throws
    /// on it. SwiftUI's `.checkbox` toggle style is AppKit-only.
    struct MacCheckbox: View {
        let title: String
        @Binding var isOn: Bool
        @Environment(\.isEnabled) private var isEnabled

        init(_ title: String, isOn: Binding<Bool>) {
            self.title = title
            _isOn = isOn
        }

        var body: some View {
            Button {
                isOn.toggle()
            } label: {
                HStack(spacing: DS.Padding.s) {
                    MacCheckboxBox(isOn: isOn)
                    Text(verbatim: title)
                        .foregroundColor(.primary)
                }
                .contentShape(Rectangle())
                // Drawn by hand, so it dims by hand as AppKit's does.
                .opacity(isEnabled ? 1 : 0.5)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: title))
            .accessibilityValue(isOn ? Text("On") : Text("Off"))
        }
    }

    /// The box alone, for a table row that is itself the click target.
    struct MacCheckboxBox: View {
        let isOn: Bool

        /// 14 screen points, the size AppKit draws a regular checkbox — in
        /// the iPad idiom's 77% points.
        private static let side: CGFloat = 18
        private let shape = RoundedRectangle(cornerRadius: 4.5, style: .continuous)

        var body: some View {
            ZStack {
                if isOn {
                    shape.fill(Color.accentColor)
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                } else {
                    shape.fill(Color(.systemBackground))
                    shape.strokeBorder(Color.primary.opacity(0.25), lineWidth: 0.75)
                }
            }
            .frame(width: Self.side, height: Self.side)
            .shadow(color: .black.opacity(isOn ? 0.12 : 0.08), radius: 0.5, y: 0.5)
            .accessibilityHidden(true)
        }
    }

    /// What a popup button shows: the current value and the up-down
    /// chevrons, on a rounded fill. Used as the label of a `Menu`, or under
    /// the UIKit button that opens the theme menu (`MacThemeMenuButton`).
    struct MacPopupLabel: View {
        let title: String

        var body: some View {
            HStack(spacing: DS.Padding.s) {
                Text(verbatim: title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundColor(.primary)
                Spacer(minLength: DS.Padding.s)
                Image(systemName: "chevron.up.chevron.down")
                    .imageScale(.small)
                    .foregroundColor(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, DS.Padding.m)
            .padding(.vertical, DS.Padding.xs + 2)
            .frame(maxWidth: 340, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                    .fill(Color(.tertiarySystemFill)),
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous))
        }
    }

#endif
