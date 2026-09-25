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
        ExecutableWatch.start { UpdateNotice.shared.isPending = true }
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
        if UserDefaults.standard.bool(forKey: "Debug.verboseTerminalLog") {
            TerminalDebugLog.enable(.standard)
        }
        return true
    }

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
    /// When that leaves the daemon holding nothing, the Mac asks its launch
    /// agent to exit as well; launchd starts it again on the next launch.
    /// The device daemon is kept alive by launchd whatever it does, so it is
    /// never asked.
    func applicationWillTerminate(_ application: UIApplication) {
        GhosttyAppConfiguration.removeTemporaryFiles()
        #if targetEnvironment(macCatalyst)
            let stopDaemon = true
        #else
            let stopDaemon = false
        #endif
        if SessionKeepAlive.isEnabled {
            let idle = application.connectedScenes
                .compactMap { ($0.delegate as? SceneDelegate)?.tabManager }
                .flatMap(\.tabs)
                .filter { !$0.hasRunningProgram }
                .compactMap(\.daemonSessionID)
            XPCDaemonTransport.closeSessionsForQuit(idle, stopDaemonWhenEmpty: stopDaemon)
        } else {
            XPCDaemonTransport.closeSessionsForQuit(nil, stopDaemonWhenEmpty: stopDaemon)
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
