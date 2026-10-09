//
//  AppName.swift
//  iGhostVTWidgets
//

import Foundation

/// The app the activity belongs to, as its header names it. The same
/// sources build the extension of both apps, iGhostVT and Ghost Remote,
/// and each target sets the name in its Info.plist (`WIDGETS_DISPLAY_NAME`).
enum AppName {
    static let text = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "iGhostVT"
}
