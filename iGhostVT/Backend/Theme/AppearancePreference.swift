//
//  AppearancePreference.swift
//  iGhostVT
//

import SwiftUI
import UIKit

/// Whether the app follows the system's light or dark setting or holds one
/// of them. It is applied as every window's `overrideUserInterfaceStyle`,
/// so the interface, the sheets, and each terminal surface — which picks
/// its light or dark theme from its trait collection — change together.
/// On the Mac, AppKit's own chrome (menus, the settings window's toolbar)
/// follows through the application's appearance.
enum AppearancePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let key = "Interface.appearance"

    var id: String {
        rawValue
    }

    static var current: AppearancePreference {
        UserDefaults.standard.string(forKey: key).flatMap(Self.init(rawValue:)) ?? .system
    }

    var userInterfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
    }

    var title: String {
        switch self {
        case .system: String(localized: "Match System")
        case .light: String(localized: "Light")
        case .dark: String(localized: "Dark")
        }
    }

    /// Every window's style, and on the Mac the application's appearance.
    /// Windows made later pick it up from the root modifier's first
    /// appearance.
    @MainActor
    static func applyToWindows() {
        let preference = current
        #if targetEnvironment(macCatalyst)
            preference.applyToApplication()
        #endif
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows where window.overrideUserInterfaceStyle != preference.userInterfaceStyle {
                window.overrideUserInterfaceStyle = preference.userInterfaceStyle
            }
        }
    }
}

#if targetEnvironment(macCatalyst)
    private extension AppearancePreference {
        /// `NSApp.appearance`, reached through the ObjC runtime as in
        /// `CatalystAccentColor`: AppKit draws the menus and the settings
        /// window's toolbar itself and never asks a UIKit window. Nil
        /// follows the system; a class or selector that is gone leaves
        /// AppKit's own appearance in place.
        var appKitAppearanceName: String? {
            switch self {
            case .system: nil
            case .light: "NSAppearanceNameAqua"
            case .dark: "NSAppearanceNameDarkAqua"
            }
        }

        @MainActor
        func applyToApplication() {
            guard let applicationClass = NSClassFromString("NSApplication") as? NSObject.Type,
                  let appearanceClass = NSClassFromString("NSAppearance") as? NSObject.Type,
                  let application = applicationClass.value(forKey: "sharedApplication") as? NSObject
            else { return }
            let setter = sel_registerName("setAppearance:")
            guard application.responds(to: setter) else { return }
            let appearance = appKitAppearanceName.flatMap { name in
                appearanceClass.perform(sel_registerName("appearanceNamed:"), with: name)?.takeUnretainedValue()
            }
            application.perform(setter, with: appearance)
        }
    }
#endif

/// Keeps every window's style in step with the preference as it changes.
private struct InterfaceAppearanceModifier: ViewModifier {
    @AppStorage(AppearancePreference.key) private var rawValue = AppearancePreference.system.rawValue

    func body(content: Content) -> some View {
        content
            .onAppear(perform: AppearancePreference.applyToWindows)
            .onChange(of: rawValue) { _ in
                AppearancePreference.applyToWindows()
            }
    }
}

extension View {
    /// Applies the light / dark preference; goes at the root of every
    /// hosting controller, beside `interfaceAccent()`.
    func interfaceAppearance() -> some View {
        modifier(InterfaceAppearanceModifier())
    }
}
