//
//  main.swift
//  iGhostVT
//

@_exported import Foundation
@_exported import UIKit

#if targetEnvironment(macCatalyst)
    // Before any scene exists: it hooks the scene's window creation.
    CatalystWindowChrome.install()
#else
    // Before UIKit reads saved sessions: a leftover archive restores whatever
    // scene delegate wrote it and never reaches the current one. Tabs come
    // back from `DaemonSessionLedger`, not from here. Not on the Mac, where
    // the same folder is AppKit's and holds the window frames. A failure
    // leaves the launch as it was before this existed, and `AppLog` is not
    // up yet to say so.
    if let bundleIdentifier = Bundle.main.bundleIdentifier,
       let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
    {
        try? SceneRestorationReset.removeSavedState(in: library, bundleIdentifier: bundleIdentifier)
    }
#endif

_ = UIApplicationMain(
    CommandLine.argc,
    CommandLine.unsafeArgv,
    nil,
    NSStringFromClass(AppDelegate.self)
)
