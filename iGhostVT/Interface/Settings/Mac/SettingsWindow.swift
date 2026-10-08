//
//  SettingsWindow.swift
//  iGhostVT
//

import SwiftUI
import UIKit

#if targetEnvironment(macCatalyst)

    /// The Mac's settings: a window of its own, as a Mac app's settings are,
    /// with a toolbar of panes along its top. iPhone and iPad keep the sheet
    /// (`settingsPresentation`).
    ///
    /// The window is a scene with its own configuration (`configurationName`,
    /// declared in Info.plist) and delegate, chosen by `AppDelegate` when the
    /// activation carries `activityType`. There is only ever one: `open()`
    /// brings the existing one forward.
    @MainActor
    enum SettingsWindow {
        static let configurationName = "Settings"
        static let activityType = "wiki.qaq.ighostvt.settings"

        static func isSettings(_ session: UISceneSession) -> Bool {
            session.configuration.name == configurationName
        }

        static func isRequested(in activities: Set<NSUserActivity>) -> Bool {
            activities.contains { $0.activityType == activityType }
        }

        /// The window up now, which shows a requested pane straight away.
        fileprivate static weak var current: SettingsSceneDelegate?
        /// A pane asked for before the window was up, taken as it connects.
        fileprivate static var requestedPane: MacSettingsPane?

        /// Opens the settings window, or brings the open one forward —
        /// showing `pane` when one is named, the last one shown otherwise.
        static func open(showing pane: MacSettingsPane? = nil) {
            if let pane {
                if let current {
                    current.show(pane)
                } else {
                    requestedPane = pane
                }
            }
            let existing = UIApplication.shared.openSessions.first(where: isSettings)
            UIApplication.shared.requestSceneSessionActivation(
                existing,
                userActivity: NSUserActivity(activityType: activityType),
                options: nil,
            ) { error in
                AppLog.error(.app, "settings window did not open: \(error)")
            }
        }
    }

    /// The settings window's scene: its toolbar picks the pane, and the
    /// window's size follows the pane — fitted to it, or fixed for a pane
    /// that scrolls.
    /// The settings window's scene: its toolbar picks the pane, and the
    /// window's size follows the pane — fitted to it, or fixed for a pane
    /// that scrolls.
    @objc(SettingsSceneDelegate)
    final class SettingsSceneDelegate: UIResponder, UIWindowSceneDelegate, NSToolbarDelegate {
        var window: UIWindow?
        private weak var windowScene: UIWindowScene?
        private let container = SettingsContainerController()
        private var pane: MacSettingsPane = .general

        private static let selectedPaneKey = "Settings.macPane"

        func scene(
            _ scene: UIScene,
            willConnectTo session: UISceneSession,
            options: UIScene.ConnectionOptions,
        ) {
            guard let windowScene = scene as? UIWindowScene else { return }
            // macOS brings back the windows the last run had open, this one
            // included. Settings is opened, not restored: a launch comes up
            // with a terminal, and this window goes again — with a terminal
            // window asked for when nothing else would make one.
            guard SettingsWindow.isRequested(in: options.userActivities) else {
                let others = UIApplication.shared.openSessions.filter { !SettingsWindow.isSettings($0) }
                if others.isEmpty {
                    TerminalWindow.requestNewWindow()
                }
                DispatchQueue.main.async {
                    UIApplication.shared.requestSceneSessionDestruction(session, options: nil)
                }
                return
            }
            self.windowScene = windowScene
            if let stored = UserDefaults.standard.string(forKey: Self.selectedPaneKey),
               let pane = MacSettingsPane(rawValue: stored)
            {
                self.pane = pane
            }
            if let requested = SettingsWindow.requestedPane {
                pane = requested
                SettingsWindow.requestedPane = nil
            }
            SettingsWindow.current = self

            if let titlebar = windowScene.titlebar {
                let toolbar = NSToolbar(identifier: "settings")
                toolbar.delegate = self
                toolbar.displayMode = .iconAndLabel
                toolbar.allowsUserCustomization = false
                titlebar.toolbar = toolbar
                titlebar.toolbarStyle = .preference
                titlebar.titleVisibility = .visible
            }
            if #available(macCatalyst 16.0, *) {
                windowScene.sizeRestrictions?.allowsFullScreen = false
            }

            container.onSizeChange = { [weak self] in self?.fit() }
            let window = SettingsHostWindow(windowScene: windowScene)
            window.rootViewController = container
            window.makeKeyAndVisible()
            self.window = window
            show(pane)
        }

        /// A relay file (or an `ighostvt://` link) opened while this window
        /// is in front: macOS hands it to the key window's scene, this one
        /// included, and a terminal window would have taken it the same way.
        func scene(_: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
            for context in contexts {
                if RelayImport.isConfiguration(context.url) {
                    RelayImport.open(context.url, in: window)
                } else {
                    ShortcutBridge.handle(context.url)
                }
            }
        }

        // MARK: - Panes

        fileprivate func show(_ pane: MacSettingsPane) {
            self.pane = pane
            UserDefaults.standard.set(pane.rawValue, forKey: Self.selectedPaneKey)
            windowScene?.title = pane.title
            windowScene?.titlebar?.toolbar?.selectedItemIdentifier = Self.identifier(of: pane)
            container.show(pane)
        }

        /// A fit waiting for the next turn of the main queue.
        private var isFitPending = false

        /// Pins the window to the pane: the pane's height plus the toolbar's,
        /// which the scene's size includes (it arrives as the window's top
        /// safe-area inset). Min and max both, so the window takes the size
        /// and cannot be dragged off it — a settings window is the size of
        /// what it shows. No animation: a spring read as sluggish beside the
        /// system's own windows.
        ///
        /// Never during a layout pass — both of its triggers arrive in one,
        /// and a window resized from inside AppKit's layout lays out again
        /// and AppKit throws on the loop. A turn later, once, and only when
        /// the size moved.
        private func fit() {
            guard !isFitPending else { return }
            isFitPending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                isFitPending = false
                applyFit()
            }
        }

        private func applyFit() {
            guard let window,
                  let restrictions = windowScene?.sizeRestrictions,
                  let height = container.paneHeight
            else { return }
            let size = CGSize(
                width: SettingsContainerController.width,
                height: height + window.safeAreaInsets.top,
            )
            guard restrictions.minimumSize != size || restrictions.maximumSize != size else { return }
            // Each bound moves out of the other's way first, or the window
            // clamps to the old one.
            if size.height > restrictions.maximumSize.height {
                restrictions.maximumSize = size
                restrictions.minimumSize = size
            } else {
                restrictions.minimumSize = size
                restrictions.maximumSize = size
            }
        }

        @objc private func selectPane(_ sender: NSToolbarItem) {
            guard let pane = MacSettingsPane(rawValue: sender.itemIdentifier.rawValue) else { return }
            show(pane)
        }

        private static func identifier(of pane: MacSettingsPane) -> NSToolbarItem.Identifier {
            NSToolbarItem.Identifier(pane.rawValue)
        }

        // MARK: - NSToolbarDelegate

        func toolbar(
            _: NSToolbar,
            itemForItemIdentifier identifier: NSToolbarItem.Identifier,
            willBeInsertedIntoToolbar _: Bool,
        ) -> NSToolbarItem? {
            guard let pane = MacSettingsPane(rawValue: identifier.rawValue) else { return nil }
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.image = UIImage(systemName: pane.symbol)
            item.label = pane.title
            item.target = self
            item.action = #selector(selectPane(_:))
            return item
        }

        func toolbarDefaultItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] {
            MacSettingsPane.allCases.map(Self.identifier(of:))
        }

        func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            toolbarDefaultItemIdentifiers(toolbar)
        }

        func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            toolbarDefaultItemIdentifiers(toolbar)
        }
    }

    /// Holds the selected pane in a hosting controller of its own, pinned
    /// under the toolbar by Auto Layout at the height SwiftUI sizes it to.
    ///
    /// The pane is laid out at the window's width (`width`), so its ideal
    /// size is its height there, and the child publishes that as its
    /// preferred content size; UIKit hands every change of it to this
    /// controller (`preferredContentSizeDidChange`) — a pane switch, or a
    /// row appearing in a pane. Nothing in the SwiftUI tree reads its own
    /// frame. While the window catches up, a taller pane runs off the
    /// bottom edge and is clipped: it is pinned at the top, never centred,
    /// which is what made the old pane slide under the toolbar on a switch.
    final class SettingsContainerController: UIViewController {
        /// The width every pane is laid out at, in the app's points.
        static let width: CGFloat = 680

        /// The pane's height or the toolbar's moved; the window follows.
        var onSizeChange: (() -> Void)?

        /// The selected pane's height, once it has one.
        private(set) var paneHeight: CGFloat?

        private var child: UIHostingController<AnyView>?
        private var heightConstraint: NSLayoutConstraint?

        override func viewDidLoad() {
            super.viewDidLoad()
            // A Mac window's own background — Catalyst maps
            // `systemBackground` to it (white, and #1E1E1E dark, on Tahoe).
            // The grouped background is the iPhone's grey, and it put the
            // window a shade off every other app's settings.
            view.backgroundColor = .systemBackground
            view.clipsToBounds = true
        }

        func show(_ pane: MacSettingsPane) {
            if let child {
                child.willMove(toParent: nil)
                child.view.removeFromSuperview()
                child.removeFromParent()
            }
            let content = Group {
                if let height = pane.fixedHeight {
                    pane.content
                        .frame(width: Self.width, height: height)
                } else {
                    pane.content
                        .frame(width: Self.width)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .interfaceTextSize()
            .interfaceAccent()
            .interfaceAppearance()
            let child = UIHostingController(rootView: AnyView(content))
            if #available(macCatalyst 16.0, *) {
                child.sizingOptions = .preferredContentSize
            }
            child.view.backgroundColor = .clear
            addChild(child)
            child.view.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child.view)
            let height = child.view.heightAnchor.constraint(equalToConstant: 0)
            NSLayoutConstraint.activate([
                child.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
                child.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                child.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                height,
            ])
            child.didMove(toParent: self)
            self.child = child
            heightConstraint = height
            // The first height, measured now: the preferred content size
            // follows on SwiftUI's next update.
            update(height: child.sizeThatFits(in: CGSize(
                width: Self.width,
                height: CGFloat.greatestFiniteMagnitude,
            )).height)
        }

        override func preferredContentSizeDidChange(forChildContentContainer container: UIContentContainer) {
            super.preferredContentSizeDidChange(forChildContentContainer: container)
            guard container === child else { return }
            update(height: container.preferredContentSize.height)
        }

        override func viewSafeAreaInsetsDidChange() {
            super.viewSafeAreaInsetsDidChange()
            onSizeChange?()
        }

        private func update(height: CGFloat) {
            let height = height.rounded(.up)
            guard height > 0, height != paneHeight else { return }
            paneHeight = height
            heightConstraint?.constant = height
            onSizeChange?()
        }
    }

    private final class SettingsHostWindow: UIWindow {
        override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
            switch action {
            case #selector(closeTab(_:)), #selector(closeWindow(_:)):
                true
            default:
                super.canPerformAction(action, withSender: sender)
            }
        }

        override func validate(_ command: UICommand) {
            super.validate(command)
            if command.action == #selector(closeTab(_:)) {
                command.title = NSLocalizedString("Close Window", comment: "Menu item: closes the window")
            }
        }

        @objc func closeTab(_: Any?) {
            closeWindow(nil)
        }

        @objc func closeWindow(_: Any?) {
            guard let session = windowScene?.session else { return }
            UIApplication.shared.requestSceneSessionDestruction(session, options: nil)
        }
    }

#endif
