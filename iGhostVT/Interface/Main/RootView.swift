//
//  RootView.swift
//  iGhostVT
//

import GhosttyTerminal
import SwiftUI

/// The window's whole interface. The `TabManager` is owned by the scene
/// delegate; this view (and everything under it) only borrows it, so each
/// window carries independent tabs.
struct RootView: View {
    @ObservedObject var tabManager: TabManager
    /// The presentations the window's menu commands can open.
    @ObservedObject var interface: WindowInterfaceState
    @ObservedObject private var theme = AppTheme.shared
    @ObservedObject private var agent = MacLaunchAgent.shared
    @StateObject private var keyboard = KeyboardState()
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var focusedTabID: UUID?
    /// Snapshot of the software keyboard as the tab switcher opened. The
    /// cover resigns the terminal, so `keyboard.isVisible` is already false
    /// by the time a card is picked; without this, leaving the overview
    /// would always look like "keyboard was down".
    @State private var keyboardVisibleBeforeSwitcher = false

    /// See `SidebarVisibility`; a UserDefaults value so View ▸ Show Sidebar
    /// can flip it from UIKit.
    @AppStorage(SidebarVisibility.key) private var showsSidebar = true

    /// User-dragged sidebar width, remembered like the visibility. The
    /// resize handle clamps it, so a stored value is always presentable.
    @AppStorage("Sidebar.width") private var sidebarWidth = 300.0
    /// The strip an iPadOS window's own controls take at its top edge
    /// (`WindowControlsInsetReader`); zero everywhere else.
    @State private var windowControls = WindowControlsInset()
    @Environment(\.layoutDirection) private var layoutDirection
    /// Whether this window shows the regular presentation — sidebar, top
    /// strip — as opposed to the phone's bottom bar. Hard-true on the Mac:
    /// a narrow Catalyst window reports a compact width class, and the
    /// phone layout there meant no top bar at all, the prompt under the
    /// traffic lights, and a pill bar at the window's foot.
    private var isRegularWidth: Bool {
        #if targetEnvironment(macCatalyst)
            true
        #else
            horizontalSizeClass == .regular
        #endif
    }

    var body: some View {
        ZStack {
            // The theme's background under everything: this is what the
            // sidebar shows, the same colour as the terminal beside it (the
            // sidebar paints nothing of its own, on the Mac or the iPad).
            theme.background(for: colorScheme)
                .ignoresSafeArea()
                .background(WindowControlsInsetReader(inset: $windowControls).ignoresSafeArea())

            HStack(spacing: 0) {
                if isRegularWidth, showsSidebar {
                    SidebarView(
                        tabManager: tabManager,
                        showsSidebar: $showsSidebar,
                        onShowSettings: { interface.showsSettingsSheet = true },
                    )
                    .frame(width: sidebarWidth)
                    .overlay(alignment: .trailing) {
                        SidebarResizeHandle(width: $sidebarWidth)
                    }
                    // Out past the safe area as well: `move` slides it by its
                    // own width from where it stands, the safe area's edge,
                    // and on a landscape iPhone its last stretch then sat in
                    // the notch's inset until the spring settled.
                    .transition(
                        .move(edge: .leading)
                            .combined(with: .offset(
                                x: layoutDirection == .rightToLeft ? windowControls.safeAreaLeading : -windowControls.safeAreaLeading,
                            )),
                    )
                }
                terminalColumn
            }
            // The animation must hang off the container, keyed on the value:
            // `showsSidebar` is `@AppStorage`, and a UserDefaults-backed write
            // does not reliably land inside a `withAnimation` transaction, so
            // wrapping the setter leaves the transition unanimated.
            .animation(DS.Motion.smooth, value: showsSidebar)
            // A windowed iPad's red, yellow and green buttons, which the
            // safe area does not keep clear: the phone layout starts under
            // them; the sidebar layout's top row moves past them instead.
            .padding(.top, isRegularWidth ? 0 : windowControls.top)
            .environment(\.windowControlsLeading, isRegularWidth ? windowControls.leading : 0)
            // The title bar is hidden and its strip is ours: the top bar
            // rides the window's edge, the sidebar clears the traffic lights
            // itself.
            .catalystIgnoresTitleBar()
        }
        .onAppear(perform: refocus)
        .onChange(of: tabManager.activeTabID) { _ in
            refocusAfterTabSwitch(softwareKeyboardWasVisible: keyboardVisibleForTabSwitch)
        }
        // Backgrounding resigns the surface's first responder (which clears
        // the FocusState through the bridge), so coming back needs the focus
        // handed out again — typing should work the moment the app does.
        .onChange(of: scenePhase) { phase in
            guard phase == .active else { return }
            refocus()
        }
        // The Mac's windows: only the key one's terminal may take the
        // keyboard, so a window gets it as it comes to the front.
        .onReceive(interface.didBecomeKey) { refocus() }
        .onAppear { interface.focusActiveTerminal = focusActiveTerminalForKeyPress }
        .onChange(of: agent.status) { _ in refocus() }
        .onChange(of: tabManager.closeRequest != nil) { _ in refocus() }
        .onChange(of: tabManager.clipboardRequests.isEmpty) { _ in refocus() }
        .onChange(of: theme.selection) { _ in
            for tab in tabManager.tabs {
                tab.terminal.controller.setTheme(
                    GhosttyAppConfiguration.theme(custom: tab.customConfiguration),
                )
            }
        }
        .onReceive(KeyboardBarStore.shared.$entries) { _ in
            for tab in tabManager.tabs {
                KeyboardBarStore.shared.apply(to: tab.terminal)
            }
        }
        // The cards' pictures are taken here, on the flip that opens the
        // cover, whichever control flipped it (the bar's button, the menu
        // command): the panes are still on screen at this point, and a
        // capture from inside the cover would be too late for any card the
        // grid lays out after the transition has removed them.
        .onChange(of: interface.showsSwitcher) { shows in
            if shows {
                keyboardVisibleBeforeSwitcher = keyboard.isVisible
                tabManager.capturePreviews()
            }
        }
        .fullScreenCover(isPresented: $interface.showsSwitcher, onDismiss: {
            refocusAfterTabSwitch(
                softwareKeyboardWasVisible: keyboardVisibleBeforeSwitcher,
            )
        }) {
            TabSwitcherView(tabManager: tabManager)
        }
        .settingsPresentation(isPresented: $interface.showsSettingsSheet, onDismiss: refocus)
        // One copy for the whole window: each confirmation presents as an
        // `AlertViewController` on the front-most context, so it lands above
        // the switcher's cover too.
        .closeTabConfirmation(tabManager)
        .sessionRestorePrompt(tabManager)
        .clipboardConfirmation(tabManager)
        .relocationPrompt(MacLaunchAgent.shared)
        .updatePrompt(UpdateNotice.shared)
    }

    private var terminalColumn: some View {
        panes
            .safeAreaInset(edge: .top, spacing: 0) {
                if isRegularWidth {
                    TabStripBar(
                        tabManager: tabManager,
                        showsSidebar: $showsSidebar,
                    )
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // The bar stays up with no tabs: `+` and settings. With a
                // tab it is the title, the iPad ⋯ menu, and the switcher.
                if !isRegularWidth, !keyboard.isVisible {
                    BottomBar(
                        tabManager: tabManager,
                        onShowSettings: { interface.showsSettingsSheet = true },
                        onShowSwitcher: { interface.showsSwitcher = true },
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .catalystColumnBackground(theme.background(for: colorScheme))
    }

    /// Every tab's surface stays mounted so background sessions keep their
    /// grid and connection; only the active one is visible and hit-testable.
    /// Insertions and removals ride the `TabManager.tabTransition` animation;
    /// switching tabs stays an instant opacity flip.
    private var panes: some View {
        ZStack {
            if tabManager.tabs.isEmpty {
                EmptyTabsView()
                    .transition(.opacity)
            }
            ForEach(tabManager.tabs) { tab in
                TerminalPane(
                    tab: tab,
                    attributes: tab.attributes,
                    isActive: tab.id == tabManager.activeTabID,
                    focusedTabID: $focusedTabID,
                    isAwaitingClose: tabManager.closeRequest === tab,
                    onCloseTab: { tabManager.requestClose(tab, from: .statusCard) },
                    onLockChange: refocus,
                    onStatusChange: refocusForStatus,
                )
                .transition(.asymmetric(
                    insertion: .opacity,
                    removal: .scale(scale: 0.92).combined(with: .opacity),
                ))
            }
        }
    }

    /// Whether the software keyboard was up as this tab switch began. The
    /// switcher's cover has already dismissed it, so that path uses the
    /// snapshot taken when the cover opened.
    private var keyboardVisibleForTabSwitch: Bool {
        interface.showsSwitcher ? keyboardVisibleBeforeSwitcher : keyboard.isVisible
    }

    /// Tab switch on iOS: raise the software keyboard only when it was
    /// already up. `requestFocus` is `becomeFirstResponder`, which pops it;
    /// the previous surface already resigned when the user tapped it away.
    /// A tap on the new terminal still toggles it. Catalyst always hands
    /// focus over — there is no software keyboard.
    private func refocusAfterTabSwitch(softwareKeyboardWasVisible: Bool) {
        guard !isCoveredByPresentation else { return }
        #if targetEnvironment(macCatalyst)
            refocus()
        #else
            guard let tab = tabManager.activeTab, !tab.isLocked else {
                focusedTabID = nil
                resignInactiveTerminals()
                return
            }
            if softwareKeyboardWasVisible || tab.isKeyboardLocked {
                refocus()
                return
            }
            focusedTabID = nil
            resignInactiveTerminals()
        #endif
    }

    /// A hidden tab that still holds first responder (keyboard lock, or a
    /// hardware accessory that is not a software keyboard) would eat keys
    /// after a switch that did not acquire the new surface.
    private func resignInactiveTerminals() {
        let active = tabManager.activeTabID
        for tab in tabManager.tabs where tab.id != active {
            guard let view = tab.terminal.attachedPlatformView, view.isFirstResponder else {
                continue
            }
            _ = view.resignFirstResponder()
        }
    }

    /// The active tab's session changed state. Into `.failed`, focus is
    /// given up outright (`refocus` sees `isCoveredByStatusAlert`) so the
    /// card can own first responder. Every other change is treated like a
    /// tab switch: a new tab's `.connecting` and `.connected` arrive right
    /// after the switch decided against the software keyboard, and a plain
    /// `refocus()` there was `becomeFirstResponder` raising it uninvited.
    private func refocusForStatus(_ status: TerminalSessionStore.Status) {
        if case .failed = status {
            refocus()
        } else {
            refocusAfterTabSwitch(softwareKeyboardWasVisible: keyboard.isVisible)
        }
    }

    /// The settings sheet or the switcher is up, and focus is theirs: a
    /// remote tab reconnecting behind the sheet changes its status, and
    /// handing the terminal first responder then took the keyboard away
    /// from the field being typed in — a device name could not be edited.
    /// Each presentation hands focus back as it is dismissed.
    private var isCoveredByPresentation: Bool {
        interface.showsSettingsSheet || interface.showsSwitcher
    }

    private var focusableActiveTab: TerminalTab? {
        // A locked tab must not hold keyboard focus: its surface ignores
        // touches, and hardware keys reaching it anyway would defeat the
        // lock. An overlay or modal alert owns first responder instead;
        // handing it to the terminal would leave the accessory bar up
        // under the card.
        guard !isCoveredByPresentation,
              let tab = tabManager.activeTab,
              !tab.isLocked,
              tabManager.closeRequest == nil,
              tabManager.clipboardRequests.isEmpty,
              !tab.isCoveredByStatusAlert
        else { return nil }
        return tab
    }

    /// A typed key arrived with no terminal focused (`TerminalWindow`): the
    /// active one takes it now, under `refocus`'s conditions, and
    /// synchronously — `requestFocus` hops the run loop and the key would
    /// arrive before it.
    private func focusActiveTerminalForKeyPress() -> UIResponder? {
        guard let tab = focusableActiveTab,
              let view = tab.terminal.attachedPlatformView
        else { return nil }
        focusedTabID = tab.id
        guard view.isFirstResponder || view.becomeFirstResponder() else { return nil }
        return view
    }

    private func refocus() {
        guard !isCoveredByPresentation else { return }
        guard let tab = focusableActiveTab else {
            focusedTabID = nil
            return
        }
        focusedTabID = tab.id
        // FocusState alone is best-effort — SwiftUI can reset it to nil
        // before the bridge acts, leaving the previous tab's surface holding
        // first responder and eating every hardware key. Hand focus over
        // imperatively so a tab switch always lands on the active terminal.
        tab.terminal.requestFocus()
    }
}

/// One tab's surface with its per-tab chrome. A separate view so the lock
/// state is actually observed: the `ForEach` in `RootView` does not watch
/// individual tabs, and a lock toggled from a context menu would otherwise
/// change nothing until an unrelated redraw. It observes the tab's
/// attributes, not the tab, which republishes on every retitle and would
/// re-evaluate the surface's whole chrome with it.
private struct TerminalPane: View {
    let tab: TerminalTab
    @ObservedObject var attributes: TabAttributes
    let isActive: Bool
    let focusedTabID: FocusState<UUID?>.Binding
    /// The close alert for this tab is up; its status card steps aside.
    let isAwaitingClose: Bool
    let onCloseTab: () -> Void
    let onLockChange: () -> Void
    let onStatusChange: (TerminalSessionStore.Status) -> Void

    /// The lock the caption is naming right now; nil once it has faded.
    @State private var announcedLock: TabLock?
    /// Bumped per announcement, so only the newest one's timer clears it.
    @State private var announcement = 0

    var body: some View {
        TerminalSurfaceView(context: tab.terminal)
            .terminalFocused(focusedTabID, equals: tab.id)
            .overlay {
                SessionStatusOverlay(
                    store: tab.store,
                    isActive: isActive,
                    isAwaitingClose: isAwaitingClose,
                    onCloseTab: onCloseTab,
                )
            }
            // Said as the lock changes, and again when a touch lands on the
            // locked surface (`lockedTouches`): the padlock on the tab's own
            // label (strip chip, title capsule, sidebar row) is what stays.
            // A caption left over the surface covered the terminal's first
            // rows for as long as the tab was locked.
            .overlay(alignment: .topTrailing) {
                if let lock = announcedLock {
                    HStack(spacing: DS.Padding.xs) {
                        TabLockBadge(lock: lock, font: DS.Font.caption)
                        Text(lock.badgeTitle)
                            .font(DS.Font.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, DS.Padding.m)
                    .padding(.vertical, DS.Padding.xs)
                    .background(.thinMaterial, in: Capsule())
                    .padding(DS.Padding.m)
                    // Badge and caption carry the same word, so the capsule
                    // is one element that says it once.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(lock.badgeTitle)
                    .transition(.opacity)
                }
            }
            .opacity(isActive ? 1 : 0)
            // The lock itself is not modeled here: `LockableTerminalView`
            // refuses hit testing and first responder at the view, so every
            // input path closes in one place while output keeps rendering.
            .allowsHitTesting(isActive)
            .accessibilityHidden(!isActive)
            .onChange(of: attributes.lock) { lock in
                announce(lock)
                onLockChange()
            }
            // A touch the lock swallowed says why it did nothing.
            .onReceive(tab.lockedTouches) {
                if isActive, let lock = attributes.lock {
                    announce(lock)
                }
            }
            // The active pane's only: a background tab's shell exiting
            // would otherwise hand the front tab's terminal first responder
            // — and the software keyboard with it — for nothing the user did.
            .onReceive(tab.store.$status) { status in
                if isActive {
                    onStatusChange(status)
                }
            }
    }

    /// Shows the caption for a newly set lock and fades it after a moment;
    /// an unlock takes it down at once.
    private func announce(_ lock: TabLock?) {
        announcement += 1
        let current = announcement
        withAnimation(DS.Motion.smooth) { announcedLock = lock }
        guard lock != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard announcement == current else { return }
            withAnimation(DS.Motion.smooth) { announcedLock = nil }
        }
    }
}

private extension View {
    @ViewBuilder
    func catalystIgnoresTitleBar() -> some View {
        #if targetEnvironment(macCatalyst)
            ignoresSafeArea(.container, edges: .top)
        #else
            self
        #endif
    }

    /// The Mac paints the theme under the terminal column only — the
    /// sidebar beside it shows the window's blur.
    @ViewBuilder
    func catalystColumnBackground(_ color: Color) -> some View {
        #if targetEnvironment(macCatalyst)
            background(color.ignoresSafeArea())
        #else
            self
        #endif
    }
}
