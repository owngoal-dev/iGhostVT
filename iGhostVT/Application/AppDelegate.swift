//
//  AppDelegate.swift
//  iGhostVT
//

import GhosttyTerminal
import UIKit

@objc(AppDelegate)
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _: UIApplication,
        didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]?,
    ) -> Bool {
        // First, so everything after it lands in this launch's journal file
        // (Settings ▸ Advanced ▸ Logs) as well as the unified log.
        AppLog.start()
        GhosttyAppConfiguration.removeTemporaryFiles()
        // A package manager replaces iGhostVT's binary in place; Ghost
        // Remote is installed whole by whatever signed it.
        if !AppEdition.isRemoteOnly {
            ExecutableWatch.start { UpdateNotice.shared.isPending = true }
        }
        // Surface lifecycle and sizing, so a surface that never comes up on
        // device says where it stopped. Input/output categories stay off —
        // they would log keystrokes.
        TerminalDebugLog.sink = { message in
            AppLog.verbose(.ghostty, message)
        }
        TerminalDebugLog.enable([.lifecycle, .metrics])
        // Full tracing (input, IME, output) is opt-in because it logs
        // keystrokes: Settings ▸ Advanced ▸ Detailed Terminal Log, or on a
        // jailbroken device
        //   defaults write wiki.qaq.iGhostVT Debug.verboseTerminalLog -bool true
        // and relaunch. The lines go where every other line goes — the
        // journal file is what to read on the device, where the unified
        // log's relay drops most of a busy launch's lines.
        if UserDefaults.standard.bool(forKey: DetailedTerminalLog.key) {
            TerminalDebugLog.enable(.standard)
        }
        // Browsing asks for the local-network permission, so only a launch
        // with a paired device to look for starts it here.
        RemoteDeviceIdentity.noteSystemName()
        RelayConfigurationStore.observeExternalChanges()
        RemoteHostDirectory.shared.startIfPaired()
        RemoteSessionCatalog.shared.start()
        // This device as a host: Ghost Remote never is one.
        if !AppEdition.isRemoteOnly {
            RemoteAccessActivity.start()
            HostSessionWatcher.shared.start()
        }
        return true
    }

    /// Every terminal window is the default configuration. The Mac's
    /// settings window asks for its own (`SettingsWindow`).
    func application(
        _: UIApplication,
        configurationForConnecting session: UISceneSession,
        options: UIScene.ConnectionOptions,
    ) -> UISceneConfiguration {
        #if targetEnvironment(macCatalyst)
            if SettingsWindow.isRequested(in: options.userActivities) {
                return UISceneConfiguration(name: SettingsWindow.configurationName, sessionRole: session.role)
            }
        #endif
        return UISceneConfiguration(name: "Default Configuration", sessionRole: session.role)
    }

    #if targetEnvironment(macCatalyst)
        /// The end of every window's responder chain, the settings window's
        /// included: Settings… and New Window still work with no terminal
        /// window in front. A terminal window answers both itself first.
        @objc func showSettings(_: Any?) {
            SettingsWindow.open()
        }

        @objc func newWindow(_: Any?) {
            TerminalWindow.requestNewWindow()
        }

        @objc func checkForUpdates(_: Any?) {
            UpdateCheck.shared.check()
        }

        /// Check for Updates… reads as what the check is doing, and does
        /// nothing more until it is done.
        override func validate(_ command: UICommand) {
            super.validate(command)
            guard command.action == #selector(checkForUpdates(_:)) else { return }
            let checker = UpdateCheck.shared
            command.title = checker.menuTitle
            command.attributes = checker.phase == .idle ? [] : .disabled
        }
    #endif

    /// The system menu bar (the Mac, an iPad with a keyboard — where it is
    /// also the hold-⌘ shortcut overlay). The Format menu goes: its ⌘T is
    /// Show Fonts, which shadows New Tab, and a terminal has no rich text
    /// for it to format anyway. `AppMenus` adds the app's own commands;
    /// `TerminalWindow` answers them.
    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard builder.system == .main else { return }
        builder.remove(menu: .format)
        AppMenus.install(into: builder)
    }

    /// An explicit quit: ⌘Q on the Mac, or a force-quit on iOS while the app
    /// is still running (a suspended app gets no notice, and its shells stay
    /// in the daemon either way).
    ///
    /// Every tab closes here the way its own × would have closed without
    /// asking: a shell sitting at its prompt has nothing to lose
    /// (`hasRunningProgram`), so it dies with the app, while a tab with a
    /// program in front of the shell stays in the daemon for the next
    /// launch to reattach. With Keep Alive off every session the daemon
    /// holds — attached to a window or not — dies, and the files the
    /// terminal staged for pastes and drops go with the last shell that
    /// could refer to them.
    ///
    /// The daemon's own exit is not asked for: once nothing is connected
    /// and nothing is held it leaves by itself, on both platforms.
    func applicationWillTerminate(_ application: UIApplication) {
        GhosttyAppConfiguration.removeTemporaryFiles()
        // Ghost Remote's tabs are other devices' sessions, which outlive
        // it whatever this switch says; each tab's link simply drops.
        guard !AppEdition.isRemoteOnly else { return }
        if SessionKeepAlive.isEnabled {
            let idle = application.connectedScenes
                .compactMap { ($0.delegate as? SceneDelegate)?.tabManager }
                .flatMap(\.tabs)
                .filter { !$0.hasRunningProgram }
                .compactMap(\.daemonSessionID)
            AppLog.info(.tabs, "quitting, killing idle sessions \(idle), keeping the rest")
            XPCDaemonTransport.closeSessionsForQuit(idle)
        } else {
            AppLog.info(.tabs, "quitting with Keep Alive off, killing every session")
            XPCDaemonTransport.closeSessionsForQuit(nil)
            TerminalFileStaging.removeAllFiles()
        }
    }
}

/// Whether daemon sessions outlive the app. On by default: a shell surviving
/// the app is the point of the daemon. Off is for a Mac (or a user) that
/// wants ⌘Q to mean what it means in Terminal.
enum SessionKeepAlive {
    static let key = "Session.keepAlive"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }
}

/// Whether a window the app opens on its own starts a shell when there is
/// nothing to resume. On by default: a terminal opens to a prompt. Off is
/// for someone who opens the app to reach what is already running — a
/// paired device's terminals, a session the CLI started — and would rather
/// see an empty window than a shell they did not ask for. A window opened
/// beside another (⌘N, New Window) is a request for a terminal and gets one
/// either way.
enum SessionLaunch {
    static let key = "Session.openAtLaunch"

    static var opensNewSession: Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }
}
