//
//  WindowControlsInset.swift
//  iGhostVT
//

import SwiftUI
import UIKit

/// How far the window's own controls reach into the top of the window:
/// the red, yellow and green buttons an iPadOS 26 window wears in its top
/// leading corner when apps are windowed. The safe area leaves them out —
/// they sit over the content — so the terminal's first row, or the
/// sidebar's title, was drawn under them. Zero in a full-screen app, on
/// an iPhone, on the Mac (whose traffic lights `CatalystWindowChrome`
/// places), and before iOS 26.
///
/// Read off a view that spans the window: the safe area adapted to the
/// window's corner, less the plain safe area, is what the controls take —
/// `top` adapted vertically (a strip above the content), `leading`
/// adapted horizontally (room beside it). The phone layout steps under
/// them; the sidebar layout's leading row steps past them, as the Mac's
/// does, so a maximized window, whose controls hide until asked for, does
/// not spend a strip on nothing.
struct WindowControlsInset: Equatable {
    var top: CGFloat = 0
    var leading: CGFloat = 0
    /// The plain safe area at the leading edge — a landscape iPhone's
    /// notch side — which the sidebar's slide has to clear. Read here
    /// because a SwiftUI `GeometryReader` in that layout reported zero.
    var safeAreaLeading: CGFloat = 0
}

struct WindowControlsInsetReader: UIViewRepresentable {
    @Binding var inset: WindowControlsInset

    func makeUIView(context _: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        view.onChange = { value in
            // Out of the layout pass that measured it: SwiftUI state
            // written from inside one is a layout loop.
            DispatchQueue.main.async { inset = value }
        }
        return view
    }

    func updateUIView(_: ProbeView, context _: Context) {}

    final class ProbeView: UIView {
        var onChange: ((WindowControlsInset) -> Void)?
        private var reported: WindowControlsInset?

        override func layoutSubviews() {
            super.layoutSubviews()
            report()
        }

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            report()
        }

        private func report() {
            let value = controlsInset
            guard value != reported else { return }
            reported = value
            onChange?(value)
        }

        private var controlsInset: WindowControlsInset {
            let safeAreaLeading = effectiveUserInterfaceLayoutDirection == .rightToLeft
                ? safeAreaInsets.right
                : safeAreaInsets.left
            #if targetEnvironment(macCatalyst)
                return WindowControlsInset(safeAreaLeading: safeAreaLeading)
            #else
                guard #available(iOS 26.0, *), window != nil else {
                    return WindowControlsInset(safeAreaLeading: safeAreaLeading)
                }
                let vertical = directionalEdgeInsets(for: .safeArea(cornerAdaptation: .vertical))
                let horizontal = directionalEdgeInsets(for: .safeArea(cornerAdaptation: .horizontal))
                return WindowControlsInset(
                    top: max(0, vertical.top - safeAreaInsets.top),
                    leading: max(0, horizontal.leading - safeAreaInsets.left),
                    safeAreaLeading: safeAreaLeading,
                )
            #endif
        }
    }
}

extension EnvironmentValues {
    // Room a windowed iPad's controls take at the window's leading edge,
    // for the row that runs along the top of the sidebar layout.
    @Entry var windowControlsLeading: CGFloat = 0
}
