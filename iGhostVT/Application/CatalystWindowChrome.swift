//
//  CatalystWindowChrome.swift
//  iGhostVT
//

import UIKit

#if targetEnvironment(macCatalyst)
    import ObjectiveC

    /// The Mac window's dressing: the title bar is hidden (`SceneDelegate`)
    /// and the app draws up to the window's top edge, so the top bar is the
    /// title bar. `install()` hooks the point where UIKit's AppKit side has
    /// just built the `NSWindow` for a scene
    /// (`UINSApplicationDelegate didCreateUIScene:transitionContext:`) to
    /// place the traffic lights on that bar and to stop AppKit drawing a
    /// titlebar fill over it. The window carries no behind-window blur: the
    /// sidebar is the terminal's background colour.
    ///
    /// All AppKit is reached through the ObjC runtime: a Catalyst target
    /// cannot import it. Every step is guarded, so an AppKit that no longer
    /// answers leaves the window plain instead of crashing.
    enum CatalystWindowChrome {
        /// UIKit points per screen point. A Catalyst app in the iPad idiom
        /// is drawn at 77%, so a distance measured on the screen — where
        /// AppKit places the traffic lights — is longer in the app's own
        /// coordinates; the Mac idiom draws 1:1.
        @MainActor private static let pointsPerScreenPoint: CGFloat =
            UIDevice.current.userInterfaceIdiom == .mac ? 1 : 1 / 0.77

        /// The strip the traffic lights live in once the title bar is
        /// hidden — the top bar's height, because the lights are moved to
        /// its vertical centre (`positionWindowControls`), so the sidebar's
        /// list starts level with the terminal under the bar.
        @MainActor static let titleBarHeight: CGFloat = TabStripBar.height

        /// The lights' height and their standard distance from the top of a
        /// window without a title bar, in screen points.
        private static let windowControlsHeight: CGFloat = 16

        /// `NSWindowStyleMaskFullSizeContentView`. Content already draws
        /// under the lights; the flag is required for
        /// `titlebarAppearsTransparent` to mean anything.
        private static let fullSizeContentViewMask: UInt = 1 << 15

        /// `NSTitlebarSeparatorStyleNone`.
        private static let titlebarSeparatorStyleNone = 1

        /// Where the traffic lights end: three 16pt buttons from x = 8, 7pt
        /// apart, so 70 screen points in. Content beside them adds its own
        /// gap — the top bar the same 8pt it keeps between its controls.
        @MainActor static let windowControlsEnd: CGFloat = 70 * pointsPerScreenPoint

        static func install() {
            guard let delegateClass = NSClassFromString("UINSApplicationDelegate") else { return }
            let selector = sel_registerName("didCreateUIScene:transitionContext:")
            guard let method = class_getInstanceMethod(delegateClass, selector) else { return }
            let original = method_getImplementation(method)
            typealias Original = @convention(c) (AnyObject, Selector, UIScene, AnyObject) -> Void
            let block: @convention(block) (AnyObject, UIScene, AnyObject) -> Void = { target, scene, context in
                unsafeBitCast(original, to: Original.self)(target, selector, scene, context)
                // AppKit runs its scene hook on the main thread; the window
                // scene and the metrics both want the main actor.
                MainActor.assumeIsolated {
                    guard let nsWindow = hostWindow(for: scene) else { return }
                    dress(nsWindow)
                    // The visual-effect views are not always in the theme
                    // frame at the scene hook; one extra pass after AppKit
                    // finishes attaching them.
                    nonisolated(unsafe) let window = nsWindow
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { dress(window) }
                    }
                    // AppKit tiles the title bar again on every resize, putting
                    // the lights back where a title bar would want them and
                    // often recreating the fill. The observer is delivered
                    // on the main queue.
                    NotificationCenter.default.addObserver(
                        forName: Notification.Name("NSWindowDidResizeNotification"),
                        object: nsWindow,
                        queue: .main,
                    ) { notification in
                        // Delivered on the main queue, so the window can be
                        // handed to the main actor without a hop.
                        nonisolated(unsafe) let window = notification.object as? NSObject
                        MainActor.assumeIsolated {
                            guard let window else { return }
                            dress(window)
                        }
                    }
                }
            }
            method_setImplementation(method, imp_implementationWithBlock(block as Any))
        }

        /// The `NSWindow` (a `UINSWindow`) AppKit built for the scene.
        @MainActor
        private static func hostWindow(for scene: UIScene) -> NSObject? {
            guard let windowScene = scene as? UIWindowScene,
                  let uiWindow = windowScene.windows.first,
                  let appClass = NSClassFromString("NSApplication") as? NSObject.Type,
                  let app = appClass.perform(NSSelectorFromString("sharedApplication"))?.takeUnretainedValue() as? NSObject,
                  let delegate = app.perform(NSSelectorFromString("delegate"))?.takeUnretainedValue() as? NSObject
            else { return nil }
            let hostWindow = sel_registerName("hostWindowForUIWindow:")
            guard delegate.responds(to: hostWindow),
                  let proxy = delegate.perform(hostWindow, with: uiWindow)?.takeUnretainedValue() as? NSObject,
                  proxy.responds(to: NSSelectorFromString("attachedWindow")),
                  let nsWindow = proxy.perform(NSSelectorFromString("attachedWindow"))?.takeUnretainedValue() as? NSObject,
                  let windowClass = NSClassFromString("UINSWindow"), nsWindow.isKind(of: windowClass)
            else { return nil }
            return nsWindow
        }

        @MainActor
        private static func dress(_ nsWindow: NSObject) {
            clearTitlebarFill(in: nsWindow)
            positionWindowControls(in: nsWindow)
        }

        /// Hiding the Catalyst title (`titleVisibility` + nil toolbar) still
        /// leaves AppKit's titlebar `NSVisualEffectView` compositing over
        /// the content. `UITitlebar` does not expose
        /// `titlebarAppearsTransparent`; Tahoe also draws
        /// `NSTitlebarBackgroundView` and `NSScrollPocket` on top of that.
        /// The traffic lights live in `NSTitlebarContainerView`, so that
        /// container stays visible.
        @MainActor
        private static func clearTitlebarFill(in nsWindow: NSObject) {
            if nsWindow.responds(to: NSSelectorFromString("setTitlebarAppearsTransparent:")) {
                nsWindow.setValue(true, forKey: "titlebarAppearsTransparent")
            }
            if nsWindow.responds(to: NSSelectorFromString("setStyleMask:")),
               let mask = nsWindow.value(forKey: "styleMask") as? NSNumber
            {
                nsWindow.setValue(mask.uintValue | fullSizeContentViewMask, forKey: "styleMask")
            }
            if nsWindow.responds(to: NSSelectorFromString("setTitlebarSeparatorStyle:")) {
                nsWindow.setValue(titlebarSeparatorStyleNone, forKey: "titlebarSeparatorStyle")
            }

            guard let contentView = nsWindow.value(forKey: "contentView") as? NSObject,
                  let themeFrame = contentView.value(forKey: "superview") as? NSObject
            else { return }

            hideDescendants(of: themeFrame, className: "NSTitlebarBackgroundView")
            hideDescendants(of: themeFrame, className: "NSScrollPocket")
            guard let container = descendants(of: themeFrame, className: "NSTitlebarContainerView").first else {
                return
            }
            hideDescendants(of: container, className: "NSVisualEffectView")
            guard let titlebarView = descendants(of: container, className: "NSTitlebarView").first else {
                return
            }
            titlebarView.setValue(true, forKey: "wantsLayer")
            if let layer = titlebarView.value(forKey: "layer") as? NSObject {
                layer.setValue(UIColor.clear.cgColor, forKey: "backgroundColor")
            }
        }

        /// Every view of that class under `root`, pre-order — a match's own
        /// subviews included, since a hidden container can still hold one.
        /// A class the runtime does not know yields none.
        @MainActor
        private static func descendants(of root: NSObject, className: String) -> [NSObject] {
            guard let cls = NSClassFromString(className) else { return [] }
            var found: [NSObject] = []
            func walk(_ view: NSObject) {
                if view.isKind(of: cls) {
                    found.append(view)
                }
                guard let subviews = view.value(forKey: "subviews") as? [NSObject] else { return }
                for sub in subviews {
                    walk(sub)
                }
            }
            walk(root)
            return found
        }

        @MainActor
        private static func hideDescendants(of root: NSObject, className: String) {
            for view in descendants(of: root, className: className) {
                view.setValue(true, forKey: "hidden")
            }
        }

        /// Centres the close, minimize, and zoom buttons on the top bar. With
        /// no title bar AppKit leaves them at a title bar's height, a few
        /// points above the bar's own controls; the bar is the title bar now.
        @MainActor
        private static func positionWindowControls(in nsWindow: NSObject) {
            typealias StandardButton = @convention(c) (AnyObject, Selector, Int) -> Unmanaged<AnyObject>?
            typealias SetOrigin = @convention(c) (AnyObject, Selector, CGPoint) -> Void
            let buttonSelector = NSSelectorFromString("standardWindowButton:")
            let originSelector = NSSelectorFromString("setFrameOrigin:")
            guard nsWindow.responds(to: buttonSelector) else { return }
            let standardButton = unsafeBitCast(nsWindow.method(for: buttonSelector), to: StandardButton.self)
            let topInset = (titleBarHeight / 2) / pointsPerScreenPoint - windowControlsHeight / 2
            for kind in 0 ... 2 { // close, miniaturize, zoom
                guard let button = standardButton(nsWindow, buttonSelector, kind)?.takeUnretainedValue() as? NSObject,
                      let frame = (button.value(forKey: "frame") as? NSValue)?.cgRectValue,
                      let superview = button.value(forKey: "superview") as? NSObject,
                      let bounds = (superview.value(forKey: "bounds") as? NSValue)?.cgRectValue
                else { continue }
                let flipped = (superview.value(forKey: "flipped") as? Bool) ?? false
                let y = flipped ? topInset : bounds.height - topInset - frame.height
                let setOrigin = unsafeBitCast(button.method(for: originSelector), to: SetOrigin.self)
                setOrigin(button, originSelector, CGPoint(x: frame.origin.x, y: y))
            }
        }
    }

    extension UIResponder {
        /// Hands the mouse event UIKit is currently delivering to AppKit as a
        /// window drag, so the chrome behaves like a title bar. Only useful
        /// from inside a touch callback: `NSApp.currentEvent` is that press.
        func dispatchTouchAsWindowMovement() {
            guard let appClass = NSClassFromString("NSApplication") as? NSObject.Type,
                  let app = appClass.value(forKey: "sharedApplication") as? NSObject,
                  let event = app.value(forKey: "currentEvent") as? NSObject,
                  let window = event.value(forKey: "window") as? NSObject
            else { return }
            window.perform(NSSelectorFromString("performWindowDragWithEvent:"), with: event)
        }
    }
#endif
