//
//  TerminalWindow.swift
//  iGhostVT
//

import Combine
import SwiftUI
import UIKit

/// Interface state a menu command has to reach: the two presentations
/// `RootView` owns. Per window, like the `TabManager` — ⇧⌘\ in one window
/// must not open the switcher in another.
final class WindowInterfaceState: ObservableObject {
    @Published var showsSwitcher = false
    @Published var showsSettingsSheet = false
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
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

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
        case #selector(exportTabText(_:)),
             #selector(increaseFontSize(_:)),
             #selector(decreaseFontSize(_:)),
             #selector(resetFontSize(_:)),
             #selector(clearScreen(_:)),
             #selector(showNextTab(_:)),
             #selector(showPreviousTab(_:)),
             #selector(toggleTabLock(_:)):
            return hasActiveTab
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

    func newTab(_: Any?) {
        _ = tabManager.newTab()
    }

    func newWindow(_: Any?) {
        Self.requestNewWindow()
    }

    /// ⌘W closes the tab; on a window with no tab left it closes the window,
    /// the way Terminal.app's ⌘W closes a window with its last tab — and
    /// with the last window, the app.
    func closeTab(_: Any?) {
        guard let tab = activeTab else { return closeEmptyWindow() }
        tabManager.requestClose(tab)
    }

    /// The Mac quits through AppKit's `terminate:` when this was the last
    /// window, so `applicationWillTerminate` runs as it does for ⌘Q — the
    /// system's own window close would leave an app with no window and no
    /// way back but the Dock. iOS destroys the scene — the system's window
    /// close, which ends the app when no window is left — and a phone, which
    /// has only the one scene, is sent home.
    private func closeEmptyWindow() {
        #if targetEnvironment(macCatalyst)
            // Another window of this app on screen: closing this one leaves
            // the app running.
            let hasOtherWindows = UIApplication.shared.connectedScenes.contains { scene in
                scene !== windowScene && scene.activationState != .unattached
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
        interface.showsSwitcher.toggle()
    }

    /// Ghostty's own font actions on the active surface — the same ones the
    /// pinch drives — with the preference stepped alongside, so the next tab
    /// opens at the size this one was just zoomed to.
    func increaseFontSize(_: Any?) {
        guard let tab = activeTab else { return }
        if tab.terminal.performBindingAction("increase_font_size:1") {
            TerminalFontSize.stepPreferred(by: 1)
        }
    }

    func decreaseFontSize(_: Any?) {
        guard let tab = activeTab else { return }
        if tab.terminal.performBindingAction("decrease_font_size:1") {
            TerminalFontSize.stepPreferred(by: -1)
        }
    }

    /// The surface goes back to the size it was configured with; the
    /// preference goes back to the platform default.
    func resetFontSize(_: Any?) {
        guard let tab = activeTab else { return }
        if tab.terminal.performBindingAction("reset_font_size") {
            TerminalFontSize.resetPreferred()
        }
    }

    func clearScreen(_: Any?) {
        _ = activeTab?.terminal.performBindingAction("clear_screen")
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
