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
            ExecutableWatch.start {
                if !UpdateNotice.shared.isRelaunching {
                    UpdateNotice.shared.isPending = true
                }
            }
        }
        // Surface lifecycle and sizing, so a surface that never comes up on
        // device says where it stopped. Input/output categories stay off —
        // they would log keystrokes.
        // This app's Wi-Fi and cellular data, which a device sold in China
        // can hold denied for an app no prompt ever asked about.
        NetworkAccess.start()
        // Remote tabs try again the moment the network comes back.
        NetworkPathWatcher.shared.start()
        // A remote tab's links stay up for a while after the app leaves.
        RemoteBackgroundGrace.install()
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
        DetailedTerminalLog.apply(UserDefaults.standard.bool(forKey: DetailedTerminalLog.key))
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
            ShortcutBridge.observeShowRequests()
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
    /// With Background Activities on every session stays in the daemon, and
    /// the next launch brings every one back as a tab, the remote tabs too
    /// (`RemoteTabLedger`, written here as well, since a Mac quit need not
    /// send a window to the background first). With it off the shells this
    /// app's own tabs run on this device's daemon die, and the files the
    /// terminal staged for pastes and drops go with the last shell that
    /// could refer to them. Only those: a remote tab's session is another
    /// device's, and a session a paired device opened on this one's daemon
    /// is that device's to end — the quit touches neither.
    ///
    /// The daemon's own exit is not asked for: once nothing is connected
    /// and nothing is held it leaves by itself, on both platforms.
    func applicationWillTerminate(_: UIApplication) {
        GhosttyAppConfiguration.removeTemporaryFiles()
        RemoteTabLedger.save(ShortcutBridge.tabManagers())
        // Ghost Remote's tabs are other devices' sessions, which outlive
        // it whatever this switch says; each tab's link simply drops.
        guard !AppEdition.isRemoteOnly else { return }
        if SessionKeepAlive.isEnabled {
            // Every session stays, idle shells included: the next launch
            // brings them all back as tabs.
            AppLog.info(.tabs, "quitting, keeping every session for the next launch to restore")
        } else {
            let local = TabManager.localSessionIDsForQuit(ShortcutBridge.tabManagers())
            AppLog.info(.tabs, "quitting with Background Activities off, killing \(local.count) local session(s)")
            if !local.isEmpty {
                XPCDaemonTransport.closeSessionsForQuit(local)
            }
            TerminalFileStaging.removeAllFiles()
            // The activity listed those shells, and no refresh is coming
            // after this to take it down.
            SessionActivityController.endForQuit()
        }
    }
}

/// Whether daemon sessions outlive the app — Settings ▸ Sessions ▸
/// Background Activities. On by default: a shell surviving the app is the
/// point of the daemon. Off is for a Mac (or a user) that wants ⌘Q to mean
/// what it means in Terminal. Ghost Remote has no sessions of its own.
///
/// Remote access holds it on: a paired device reaches this one's
/// terminals, and a quit that ended them would end what a device was
/// using or meant to come back to. The switch shows on and cannot be
/// turned off while remote access is on, and the choice stored under it
/// waits until remote access goes off again.
enum SessionKeepAlive {
    static let key = "Session.keepAlive"
    /// The helper's remote-access switch as this app last heard it
    /// (`HostSessionWatcher`, which every status read anywhere reaches),
    /// so a quit decides without asking the daemon.
    static let remoteAccessKey = "Session.remoteAccessOn"

    static var isEnabled: Bool {
        isHeldByRemoteAccess || (UserDefaults.standard.object(forKey: key) as? Bool ?? true)
    }

    static var isHeldByRemoteAccess: Bool {
        UserDefaults.standard.bool(forKey: remoteAccessKey)
    }

    static func noteRemoteAccess(_ isOn: Bool) {
        guard isOn != isHeldByRemoteAccess else { return }
        UserDefaults.standard.set(isOn, forKey: remoteAccessKey)
    }
}

/// Whether a window the app opens on its own starts a shell when there is
/// nothing to resume. On by default: a terminal opens to a prompt. Off is
/// for someone who opens the app to reach what is already running — a
/// paired device's terminals, a session the CLI started — and would rather
/// see an empty window than a shell they did not ask for. A window opened
/// beside another (⌘N, New Window) is a request for a terminal and gets one
/// either way. The shell is always this device's — a launch never opens one
/// on a paired device — so Ghost Remote neither reads nor offers it.
enum SessionLaunch {
    static let key = "Session.openAtLaunch"

    static var opensNewSession: Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }
}
