//
//  WindowTranslucency.swift
//  iGhostVT
//

import UIKit

enum WindowTranslucency {
    static let opacityKey = "Window.backgroundOpacity"
    static let blurRadiusKey = "Window.blurRadius"

    private static let opacityRange: ClosedRange<Double> = 0.1 ... 1
    private static let blurRadiusRange: ClosedRange<Int> = 0 ... 64
    private static let defaultBlurRadius = 20

    static let opacity: Double = {
        #if targetEnvironment(macCatalyst)
            let stored = UserDefaults.standard.object(forKey: opacityKey) as? Double ?? 1
            return min(max(stored, opacityRange.lowerBound), opacityRange.upperBound)
        #else
            return 1
        #endif
    }()

    static let blurRadius: Int = {
        let stored = UserDefaults.standard.object(forKey: blurRadiusKey) as? Int ?? defaultBlurRadius
        return min(max(stored, blurRadiusRange.lowerBound), blurRadiusRange.upperBound)
    }()

    static var isEnabled: Bool {
        opacity < 1
    }

    #if targetEnvironment(macCatalyst)
        @MainActor
        static func prepare(_ window: UIWindow) {
            guard isEnabled else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            window.rootViewController?.view.isOpaque = false
            window.rootViewController?.view.backgroundColor = .clear
        }

        @MainActor
        static func apply(to nsWindow: NSObject) {
            guard isEnabled, objc_getAssociatedObject(nsWindow, &appliedKey) == nil else { return }
            objc_setAssociatedObject(nsWindow, &appliedKey, true, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            nsWindow.setValue(false, forKey: "opaque")
            if let faintBackground {
                nsWindow.setValue(faintBackground, forKey: "backgroundColor")
            }
            setBlur(blurRadius, on: nsWindow)
            _ = nsWindow.perform(NSSelectorFromString("invalidateShadow"))
        }

        @MainActor private static var appliedKey: UInt8 = 0

        @MainActor
        private static var faintBackground: NSObject? {
            guard let colorClass = NSClassFromString("NSColor") as? NSObject.Type,
                  let white = colorClass.perform(NSSelectorFromString("whiteColor"))?.takeUnretainedValue() as? NSObject
            else { return nil }
            typealias WithAlpha = @convention(c) (NSObject, Selector, CGFloat) -> NSObject
            let selector = NSSelectorFromString("colorWithAlphaComponent:")
            guard let implementation = white.method(for: selector) else { return nil }
            return unsafeBitCast(implementation, to: WithAlpha.self)(white, selector, 0.001)
        }

        private typealias DefaultConnection = @convention(c) () -> Int32
        private typealias SetBlurRadius = @convention(c) (Int32, Int, Int) -> Int32

        @MainActor
        private static func setBlur(_ radius: Int, on nsWindow: NSObject) {
            let handle = UnsafeMutableRawPointer(bitPattern: -2)
            guard let connectionSymbol = dlsym(handle, "CGSDefaultConnectionForThread"),
                  let blurSymbol = dlsym(handle, "CGSSetWindowBackgroundBlurRadius"),
                  let number = nsWindow.value(forKey: "windowNumber") as? Int, number > 0
            else {
                AppLog.warning(.app, "window blur unavailable")
                return
            }
            let connection = unsafeBitCast(connectionSymbol, to: DefaultConnection.self)()
            let status = unsafeBitCast(blurSymbol, to: SetBlurRadius.self)(connection, number, radius)
            if status != 0 {
                AppLog.warning(.app, "window \(number) blur radius \(radius) refused, status \(status)")
            }
        }
    #endif
}
