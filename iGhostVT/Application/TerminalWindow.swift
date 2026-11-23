//
//  TerminalWindow.swift
//  iGhostVT
//

import Combine
import SwiftUI
import UIKit

/// Interface state a menu command has to reach: the two presentations the
/// window has. Per window, like the `TabManager` — ⇧⌘\ in one window must
/// not open the switcher in another.
///
/// Main-actor bound: every caller is a window, a scene delegate or a view,
/// and the overview is presented a turn or a transition after the tap that
/// asked for it.
@MainActor
final class WindowInterfaceState: ObservableObject {
    /// Whether the tab overview is on screen. It follows the panel that is
    /// presenting it (`openSwitcher`): there is no request to go stale,
    /// because nothing but a panel on screen puts it up.
    @Published private(set) var showsSwitcher = false
    @Published var showsSettingsSheet = false
    /// The window just became key — on the Mac, came to the front — and its
    /// terminal may take the keyboard again. Sent on the Mac only.
    let didBecomeKey = PassthroughSubject<Void, Never>()
    /// Gives the active terminal first responder for a typed key, if it may
    /// take it, and returns it. Set by `RootView`; the closure holds the
    /// view and the view holds this state, so `SceneDelegate` clears it as
    /// the window goes.
    var focusActiveTerminal: (() -> UIResponder?)?
    /// The overview is about to cover the panes: take the cards' pictures and
    /// remember whether the keyboard was up, while both are still on screen.
    var willShowSwitcher: (() -> Void)?
    /// The overview has gone, and the keyboard it took with it may come back.
    var didHideSwitcher: (() -> Void)?

    /// The window the overview is presented in, and the tabs it lists; both
    /// set by `TerminalWindow`.
    weak var window: UIWindow?
    weak var tabManager: TabManager?

    /// Settings, opened on Remote Access: where Ghost Remote sends a new
    /// tab with no paired device to open on.
    @MainActor
    func showRemoteAccess() {
        SettingsSheet.remoteAccessRequest.send(true)
        showsSettingsSheet = true
    }

    // MARK: - The tab overview

    /// The panel, from the request until it leaves the screen.
    private var switcherPanel: TabSwitcherPanel?
    /// The pending "has it taken the window yet" check.
    private var switcherAttempt: DispatchWorkItem?
    /// How long a present is retried before the overview is given up. A menu
    /// on its way out takes about a third of a second; this is six of them.
    private static let switcherPresentLimit: TimeInterval = 2

    /// The overview is up, or on its way in — what keeps `RootView` from
    /// handing the terminal focus while the panel covers it.
    var isSwitcherShowing: Bool {
        showsSwitcher || switcherPanel != nil
    }

    /// Opens the overview, from the bar's button or from ⇧⌘\.
    ///
    /// SwiftUI's `fullScreenCover` presents on the *change* to true and keeps
    /// the flag up when UIKit refuses the request. UIKit refuses one made
    /// while something else is being presented or dismissed, and the bar's
    /// ⋯ menu closes over the same window: tapping the overview's button as
    /// it went left the flag up with nothing on screen, and every later tap
    /// wrote true to a value already true — the button dead until the app
    /// was restarted.
    ///
    /// Presented here against the window instead. A present the window will
    /// not take is not recorded as one that landed: the panel says whether
    /// it is on screen, and the request is made again until it is.
    func openSwitcher() {
        guard switcherPanel == nil else { return }
        guard let window, let host = window.rootViewController, let tabManager else { return }
        let panel = TabSwitcherPanel(tabManager: tabManager) { [weak self] in
            self?.closeSwitcher()
        }
        panel.onAppear = { [weak self] in
            self?.showsSwitcher = true
        }
        panel.onDisappear = { [weak self] in
            self?.switcherDidDisappear()
        }
        switcherPanel = panel
        willShowSwitcher?()
        presentSwitcher(panel, on: host, until: CFAbsoluteTimeGetCurrent() + Self.switcherPresentLimit)
    }

    /// ⇧⌘\ — the one control that both opens and closes the overview, as the
    /// menu item has always been.
    func toggleSwitcher() {
        if switcherPanel != nil {
            closeSwitcher()
        } else {
            openSwitcher()
        }
    }

    /// Takes the overview down — Done, a card, ⇧⌘\, or a relay file that
    /// needs the window and cannot have the panel.
    func closeSwitcher() {
        switcherAttempt?.cancel()
        switcherAttempt = nil
        guard let panel = switcherPanel else { return }
        guard panel.presentingViewController != nil else {
            // It never reached the screen; forget it so the next tap can ask.
            switcherPanel = nil
            return
        }
        guard !panel.isBeingDismissed else { return }
        panel.dismiss(animated: true)
    }

    private func switcherDidDisappear() {
        switcherAttempt?.cancel()
        switcherAttempt = nil
        switcherPanel = nil
        showsSwitcher = false
        didHideSwitcher?()
    }

    /// Presents the panel, or looks again in a moment.
    ///
    /// `present` fails without an error while another presentation is in
    /// progress, and the panel's `presentingViewController` is what says it
    /// took. What is over the window when the tap arrives is not ours — the
    /// bar is reachable only where nothing covers it, so it is a menu on its
    /// way out — and the present is held back rather than made over it.
    private func presentSwitcher(
        _ panel: TabSwitcherPanel,
        on host: UIViewController,
        until deadline: CFAbsoluteTime,
    ) {
        guard switcherPanel === panel, panel.presentingViewController == nil else { return }
        guard CFAbsoluteTimeGetCurrent() < deadline else {
            AppLog.warning(.tabs, "the tab overview was not presented: the window stayed busy")
            switcherPanel = nil
            return
        }
        if host.presentedViewController == nil {
            host.present(panel, animated: true)
        }
        guard panel.presentingViewController == nil else { return }
        let attempt = DispatchWorkItem { [weak self, weak panel] in
            guard let self, let panel else { return }
            presentSwitcher(panel, on: host, until: deadline)
        }
        switcherAttempt?.cancel()
        switcherAttempt = attempt
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: attempt)
    }
}

/// The sidebar's visibility, a UserDefaults value so a menu command can flip
/// it from UIKit while `RootView` observes it through `@AppStorage`. Compact
/// width never shows a sidebar, so this only describes iPad-sized layouts.
enum SidebarVisibility {
    static let key = "Sidebar.visible"

    /// Open by default at regular width, the way Safari shows its sidebar on
    /// iPad, and remembered once the user takes a side.
    static var isVisible: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

/// The window is the one responder every key press passes through — the
/// terminal's, a sheet's, the switcher's — so the menu commands live here
/// and reach the tabs of whichever window has focus. `canPerformAction`
/// is what the menu bar and the iPad's hold-⌘ overlay consult, so a command
/// that would do nothing (no tab, a modal on top, no sidebar at this width)
/// reads as disabled instead of failing silently.
final class TerminalWindow: UIWindow, AppCommandResponder {
    let tabManager: TabManager
    let interface: WindowInterfaceState

    init(windowScene: UIWindowScene, tabManager: TabManager, interface: WindowInterfaceState) {
        self.tabManager = tabManager
        self.interface = interface
        super.init(windowScene: windowScene)
        // The overview is presented by the interface state itself, against
        // this window (`WindowInterfaceState.openSwitcher`).
        interface.window = self
        interface.tabManager = tabManager
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    #if targetEnvironment(macCatalyst)
        /// A terminal behind the key window refuses first responder
        /// (`LockableTerminalView`), so a window coming forward is when its
        /// active tab gets the keyboard back.
        override func becomeKey() {
            super.becomeKey()
            interface.didBecomeKey.send()
        }
    #endif

    /// Opens a new window scene (its own `TabManager`) on devices that
    /// support multiple scenes; no-op elsewhere.
    static func requestNewWindow() {
        guard UIApplication.shared.supportsMultipleScenes else { return }
        UIApplication.shared.requestSceneSessionActivation(
            nil,
            userActivity: nil,
            options: nil,
            errorHandler: nil,
        )
    }

    // MARK: - Typing Without Focus

    /// The presses this window handed to a terminal, each with the terminal
    /// it went to, so the rest of that press follows it there — even after a
    /// later key went to another tab's.
    private var forwardedPresses: [UIPress: UIResponder] = [:]

    /// A typed key no responder took: a tab that came up without the
    /// keyboard (iOS focuses a new or switched-to tab only while the
    /// onscreen keyboard is up) takes it, and the key with it, so the first
    /// key on a hardware keyboard is not lost. Not while the focus system
    /// has something focused (Full Keyboard Access, the Mac's keyboard
    /// navigation): Tab, the arrows, Space and Return move that focus.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard presses.allSatisfy(Self.isTypingPress),
              !isShowingModal,
              UIFocusSystem.focusSystem(for: self)?.focusedItem == nil,
              let terminal = interface.focusActiveTerminal?()
        else {
            super.pressesBegan(presses, with: event)
            return
        }
        for press in presses {
            forwardedPresses[press] = terminal
        }
        terminal.pressesBegan(presses, with: event)
    }

    override func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = forward(presses, ending: false) { $0.pressesChanged($1, with: event) }
        if !rest.isEmpty { super.pressesChanged(rest, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = forward(presses, ending: true) { $0.pressesEnded($1, with: event) }
        if !rest.isEmpty { super.pressesEnded(rest, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = forward(presses, ending: true) { $0.pressesCancelled($1, with: event) }
        if !rest.isEmpty { super.pressesCancelled(rest, with: event) }
    }

    /// Delivers each forwarded press to its terminal, forgetting it when the
    /// press is over, and returns the presses that were never forwarded.
    private func forward(
        _ presses: Set<UIPress>,
        ending: Bool,
        deliver: (UIResponder, Set<UIPress>) -> Void,
    ) -> Set<UIPress> {
        var rest = presses
        for press in presses {
            let terminal = ending ? forwardedPresses.removeValue(forKey: press) : forwardedPresses[press]
            guard let terminal else { continue }
            rest.remove(press)
            deliver(terminal, [press])
        }
        return rest
    }

    private static func isTypingPress(_ press: UIPress) -> Bool {
        guard let key = press.key else { return false }
        if key.modifierFlags.contains(.command) || KeyShortcuts.shortcut(for: key) != nil { return false }
        switch key.keyCode {
        case .keyboardLeftShift, .keyboardRightShift, .keyboardLeftControl, .keyboardRightControl,
             .keyboardLeftAlt, .keyboardRightAlt, .keyboardLeftGUI, .keyboardRightGUI,
             .keyboardCapsLock, .keyboardLANG1, .keyboardLANG2:
            return false
        default:
            return true
        }
    }

    // MARK: - Validation

    /// A sheet, the switcher, or an alert on top: tab commands would act on
    /// what is underneath, so only the switcher's own toggle stays live — it
    /// is how ⇧⌘\ exits the overview it opened.
    private var isShowingModal: Bool {
        rootViewController?.presentedViewController != nil
    }

    private var activeTab: TerminalTab? {
        tabManager.activeTab
    }

    private var hasActiveTab: Bool {
        !isShowingModal && activeTab != nil
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        switch action {
        case #selector(newTab(_:)), #selector(showSettings(_:)), #selector(closeTab(_:)):
            return !isShowingModal
        case #selector(toggleTabSwitcher(_:)):
            return !isShowingModal || interface.showsSwitcher
        case #selector(newWindow(_:)), #selector(closeWindow(_:)):
            return UIApplication.shared.supportsMultipleScenes
        case #selector(toggleTabSidebar(_:)):
            return !isShowingModal && traitCollection.horizontalSizeClass == .regular
        case #selector(selectTab(_:)):
            guard hasActiveTab, let index = Self.tabIndex(of: sender) else { return false }
            return tab(atCommandIndex: index) != nil
        case #selector(increaseFontSize(_:)):
            return hasActiveTab && activeTab?.fontSize.canStep(by: 1) == true
        case #selector(decreaseFontSize(_:)):
            return hasActiveTab && activeTab?.fontSize.canStep(by: -1) == true
        case #selector(resetFontSize(_:)):
            return hasActiveTab && activeTab?.attributes.fontOffset != 0
        case #selector(exportTabText(_:)),
             #selector(clearScreen(_:)),
             #selector(showNextTab(_:)),
             #selector(showPreviousTab(_:)),
             #selector(toggleTabLock(_:)):
            return hasActiveTab
        case #selector(findInTerminal(_:)),
             #selector(findNextMatch(_:)),
             #selector(findPreviousMatch(_:)),
             #selector(findSelection(_:)):
            return hasActiveTab && activeTab?.isCoveredByStatusAlert == false
        case #selector(toggleKeyboardLock(_:)):
            // Not offered on the Mac; anything that still asks (nothing
            // should) reads it as disabled rather than half-working.
            #if targetEnvironment(macCatalyst)
                return false
            #else
                return hasActiveTab
            #endif
        default:
            return super.canPerformAction(action, withSender: sender)
        }
    }

    /// Titles and checkmarks that follow the state they toggle.
    override func validate(_ command: UICommand) {
        super.validate(command)
        switch command.action {
        case #selector(toggleTabSidebar(_:)):
            command.title = SidebarVisibility.isVisible
                ? NSLocalizedString("Hide Sidebar", comment: "Menu item: hides the tab sidebar")
                : NSLocalizedString("Show Sidebar", comment: "Menu item: shows the tab sidebar")
        case #selector(toggleTabSwitcher(_:)):
            command.title = interface.showsSwitcher
                ? NSLocalizedString("Exit Tab Overview", comment: "Menu item: closes the tab overview")
                : NSLocalizedString("Show All Tabs", comment: "Menu item: opens the tab overview")
        case #selector(closeTab(_:)):
            // With no tab left ⌘W closes the window, and the menu says so.
            command.title = activeTab == nil
                ? NSLocalizedString("Close Window", comment: "Menu item: closes the window")
                : NSLocalizedString("Close Tab", comment: "Menu item: closes the active terminal tab")
        case #selector(toggleTabLock(_:)):
            command.state = activeTab?.isLocked == true ? .on : .off
        case #selector(toggleKeyboardLock(_:)):
            command.state = activeTab?.isKeyboardLocked == true ? .on : .off
        default:
            break
        }
    }

    private static func tabIndex(of sender: Any?) -> Int? {
        (sender as? UICommand)?.propertyList as? Int
    }

    /// The tab a Go to Tab command names, or nil when its index has none.
    private func tab(atCommandIndex index: Int) -> TerminalTab? {
        let tabs = tabManager.tabs
        if index == AppMenus.lastTabIndex {
            return tabs.last
        }
        return tabs.indices.contains(index) ? tabs[index] : nil
    }

    // MARK: - File

    /// ⌘T copies the active tab — its device, its directory — right beside
    /// it. ⌘N, its hidden alias, is a fresh local shell at the end.
    func newTab(_ sender: Any?) {
        if (sender as? UIKeyCommand)?.propertyList as? String == AppMenus.aliasPropertyList {
            _ = tabManager.newTab(.home)
        } else {
            _ = tabManager.newTab(besideActiveTab: true)
        }
    }

    func newWindow(_: Any?) {
        Self.requestNewWindow()
    }

    /// ⌘W closes the tab; on a window with no tab left it closes the window,
    /// the way Terminal.app's ⌘W closes a window with its last tab — and
    /// with the last window, the app.
    func closeTab(_: Any?) {
        guard let tab = activeTab else { return closeEmptyWindow() }
        tabManager.requestClose(tab, from: .keyCommand)
    }

    /// The Mac quits through AppKit's `terminate:` when this was the last
    /// window, so `applicationWillTerminate` runs as it does for ⌘Q — the
    /// system's own window close would leave an app with no window and no
    /// way back but the Dock. iOS destroys the scene — the system's window
    /// close, which ends the app when no window is left — and a phone, which
    /// has only the one scene, is sent home.
    private func closeEmptyWindow() {
        #if targetEnvironment(macCatalyst)
            // Another terminal window on screen: closing this one leaves
            // the app running. The settings window does not count — it is
            // no reason to keep an app with no terminal open.
            let hasOtherWindows = UIApplication.shared.connectedScenes.contains { scene in
                scene !== windowScene
                    && scene.activationState != .unattached
                    && !SettingsWindow.isSettings(scene.session)
            }
            if hasOtherWindows {
                closeWindow(nil)
            } else {
                AppTermination.terminate()
            }
        #else
            if UIApplication.shared.supportsMultipleScenes {
                closeWindow(nil)
            } else {
                _ = UIApplication.shared.perform(NSSelectorFromString("suspend"))
            }
        #endif
    }

    /// The same path as the window's close button: the scene disconnects
    /// and its tabs detach, leaving the daemon's shells running.
    func closeWindow(_: Any?) {
        guard let session = windowScene?.session else { return }
        UIApplication.shared.requestSceneSessionDestruction(session, options: nil, errorHandler: nil)
    }

    func exportTabText(_: Any?) {
        guard let tab = activeTab else { return }
        TabPageExport.exportText(of: tab, in: self)
    }

    func showSettings(_: Any?) {
        interface.showsSettingsSheet = true
    }

    // MARK: - View

    func toggleTabSidebar(_: Any?) {
        SidebarVisibility.isVisible.toggle()
    }

    func toggleTabSwitcher(_: Any?) {
        interface.toggleSwitcher()
    }

    /// The active tab a point bigger or smaller, or back to Settings ▸
    /// Text Size: its offset (`TabFontSize`), never the setting, so no
    /// other tab and no later one changes with it.
    func increaseFontSize(_: Any?) {
        activeTab?.fontSize.step(by: 1)
    }

    func decreaseFontSize(_: Any?) {
        activeTab?.fontSize.step(by: -1)
    }

    func resetFontSize(_: Any?) {
        activeTab?.fontSize.reset()
    }

    func clearScreen(_: Any?) {
        _ = activeTab?.terminal.performBindingAction("clear_screen")
    }

    // MARK: - Find

    func findInTerminal(_: Any?) {
        activeTab?.search.present()
    }

    func findNextMatch(_: Any?) {
        activeTab?.search.navigate(.older)
    }

    func findPreviousMatch(_: Any?) {
        activeTab?.search.navigate(.newer)
    }

    func findSelection(_: Any?) {
        _ = activeTab?.terminal.performBindingAction("search_selection")
    }

    // MARK: - Window

    func showNextTab(_: Any?) {
        tabManager.activateAdjacentTab(offset: 1)
    }

    func showPreviousTab(_: Any?) {
        tabManager.activateAdjacentTab(offset: -1)
    }

    func selectTab(_ sender: Any?) {
        guard let index = Self.tabIndex(of: sender), let tab = tab(atCommandIndex: index) else { return }
        tabManager.activeTabID = tab.id
    }

    func toggleTabLock(_: Any?) {
        activeTab?.isLocked.toggle()
    }

    func toggleKeyboardLock(_: Any?) {
        activeTab?.isKeyboardLocked.toggle()
    }
}
