//
//  LockableTerminalView.swift
//  iGhostVT
//

import GameController
import GhosttyTerminal
import UIKit

/// The app's terminal view: `TerminalView` plus the two locks.
///
/// A locked tab freezes the *user*, never the program: output keeps
/// flowing, the surface keeps rendering, the session keeps running. The
/// blocking therefore lives here, at the view — refuse hit testing, first
/// responder, or the keyboard, and every path into the terminal is closed at
/// its end — instead of being scattered across SwiftUI modifiers that each
/// have to remember. Installed through `TerminalViewState.makePlatformView`
/// (see `TerminalTab`).
final class LockableTerminalView: TerminalView {
    /// When true the view refuses every interaction: touches never land
    /// (`hitTest` returns nil) and keyboard focus is refused and released,
    /// which closes the hardware-key path too.
    var isInteractionLocked = false {
        didSet {
            updateAccessibility()
            guard isInteractionLocked, isFirstResponder else { return }
            resignFirstResponder()
        }
    }

    /// Keyboard lock: the software keyboard stays down. Touches, scrolling,
    /// selection, and hardware keys stay live — only the on-screen keyboard
    /// is refused.
    ///
    /// Swallowing the tap toggle is not enough on its own: the library
    /// becomes first responder from several other places — the long-press
    /// selection menu, a pointer click, the host's own `requestFocus` after a
    /// sheet dismisses — and each of those brought the keyboard back up. So
    /// the lock is enforced where every one of those paths ends instead, at
    /// the input view.
    var isSoftwareKeyboardLocked = false {
        didSet {
            guard isSoftwareKeyboardLocked != oldValue else { return }
            updateAccessibility()
            // The iPad shortcuts bar is not part of `inputAccessoryView`, and
            // an empty keyboard leaves it (and its dictation button) floating
            // over the terminal, stealing 40pt of grid. Empty its groups for
            // as long as the lock lasts.
            #if !os(visionOS)
                inputAssistantItem.leadingBarButtonGroups = []
                inputAssistantItem.trailingBarButtonGroups = []
            #endif
            guard isFirstResponder else { return }
            // Already first responder: swap the input views in place, so
            // locking drops the keyboard that is up and unlocking brings it
            // back without the user having to tap again.
            reloadInputViews()
        }
    }

    /// What the terminal offers UIKit as its keyboard while locked. An empty
    /// view keeps first-responder status — and with it the hardware key
    /// path — while leaving nothing to raise.
    private lazy var suppressedInputView = UIView(frame: .zero)

    override var canBecomeFirstResponder: Bool {
        !isInteractionLocked && super.canBecomeFirstResponder
    }

    override var inputView: UIView? {
        isSoftwareKeyboardLocked ? suppressedInputView : super.inputView
    }

    #if !os(visionOS)
        override var inputAccessoryView: UIView? {
            // The bar belongs to the keyboard; leaving it floating over a
            // keyboard that is not there reads as a half-open keyboard. With a
            // hardware keyboard connected the user may not want it at all.
            if isSoftwareKeyboardLocked {
                return nil
            }
            if KeyboardBarStore.hidesWithHardwareKeyboard, GCKeyboard.coalesced != nil {
                return nil
            }
            return super.inputAccessoryView
        }
    #endif

    /// A keyboard connecting or going away, or the setting flipping,
    /// changes the answer above; UIKit only asks again on reload.
    private var observesHardwareKeyboard = false

    private func observeHardwareKeyboard() {
        observesHardwareKeyboard = true
        let center = NotificationCenter.default
        for name in [.GCKeyboardDidConnect, .GCKeyboardDidDisconnect, UserDefaults.didChangeNotification] {
            center.addObserver(self, selector: #selector(hardwareKeyboardChanged), name: name, object: nil)
        }
    }

    /// Nonisolated: `UserDefaults.didChangeNotification` is posted on
    /// whatever thread wrote the default (PencilKit's `registerDefaults`
    /// from a background queue was the first), and a main-actor method
    /// called there traps before it can hop.
    @objc private nonisolated func hardwareKeyboardChanged() {
        Task { @MainActor [weak self] in
            guard let self, isFirstResponder else { return }
            reloadInputViews()
        }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        isInteractionLocked ? nil : super.hitTest(point, with: event)
    }

    // MARK: - Accessibility

    /// The surface is one VoiceOver element: it draws its own grid, so there
    /// is nothing underneath for assistive technology to walk into. An
    /// interaction-locked view is no element at all — it refuses hit testing
    /// and first responder there, and an element would be a way back in;
    /// the pane's lock capsule still announces that state beside it.
    private func updateAccessibility() {
        isAccessibilityElement = !isInteractionLocked
        accessibilityLabel = String(localized: "Terminal")
        // Only the keyboard lock can be read here — the interaction lock
        // removes the element above. `TabLock` owns the wording the badge
        // and the capsule already speak.
        accessibilityValue = isSoftwareKeyboardLocked ? TabLock.keyboard.badgeTitle : nil
        // Output arrives without the user doing anything to prompt it.
        accessibilityTraits.insert(.updatesFrequently)
    }

    // MARK: - The app's shortcuts

    /// Presses taken by the app; their release must not reach the surface
    /// either, or ghostty sees a key go up that never came down.
    private var interceptedPresses: Set<UIPress> = []

    /// The app's chords (`KeyShortcuts`) go to the responder chain — the
    /// window answers, through `canPerformAction`, so a chord a menu item
    /// would grey out does nothing rather than reaching the shell. Every
    /// other press is the library's: the terminal's `pressesBegan` never
    /// calls `super`, so UIKit sees each key as handled and the menu's key
    /// commands never fire while a terminal has focus — which is why the
    /// claim has to be made here, before the library. Escape is never in
    /// the list: it always reaches the terminal.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var remaining = presses
        for press in presses {
            guard let key = press.key, let shortcut = KeyShortcuts.shortcut(for: key) else { continue }
            remaining.remove(press)
            interceptedPresses.insert(press)
            let sender = UICommand(title: "", action: shortcut.action, propertyList: shortcut.propertyList)
            UIApplication.shared.sendAction(shortcut.action, to: nil, from: sender, for: nil)
        }
        if !remaining.isEmpty {
            super.pressesBegan(remaining, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let remaining = presses.subtracting(interceptedPresses)
        interceptedPresses.subtract(presses)
        if !remaining.isEmpty {
            super.pressesEnded(remaining, with: event)
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let remaining = presses.subtracting(interceptedPresses)
        interceptedPresses.subtract(presses)
        if !remaining.isEmpty {
            super.pressesCancelled(remaining, with: event)
        }
    }

    #if !targetEnvironment(macCatalyst)
        /// The library's tap path calls this after the tap's click has been
        /// sent; only the keyboard raise/dismiss is ours to swallow. On
        /// Catalyst there is no software keyboard and no such member.
        override func toggleSoftwareKeyboard() {
            guard !isSoftwareKeyboardLocked else { return }
            super.toggleSoftwareKeyboard()
        }
    #endif

    /// Retains the drop delegate: `UIDropInteraction` holds its delegate
    /// weakly, and non-nil is also the flag that the swap already happened.
    private var dropDelegate: TerminalDropDelegate?

    /// Swaps the library's drop handling for the app's
    /// (`TerminalDropDelegate`): a real path on the Mac, a staged copy on
    /// iOS, folders on both, and named-by-type files for data that has no
    /// file behind it.
    ///
    /// The library's `dropInteraction(_:performDrop:)` is `public`, not
    /// `open`, so a subclass cannot override it — replacing the whole
    /// interaction is what a host can do. The library installs its
    /// interaction from `setupPlatformInput()` during init, so by the time
    /// there is a window it is there to remove.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateAccessibility()
        if !observesHardwareKeyboard {
            observeHardwareKeyboard()
        }
        guard window != nil, dropDelegate == nil else { return }
        for interaction in interactions where interaction is UIDropInteraction {
            removeInteraction(interaction)
        }
        let delegate = TerminalDropDelegate(terminal: self)
        dropDelegate = delegate
        addInteraction(UIDropInteraction(delegate: delegate))
    }
}
