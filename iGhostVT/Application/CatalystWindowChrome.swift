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
                    // The settings window keeps AppKit's own title bar and
                    // its toolbar of panes.
                    guard !SettingsWindow.isSettings(scene.session),
                          let nsWindow = hostWindow(for: scene)
                    else { return }
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

        /// Where the pointer is, in AppKit's screen coordinates (points,
        /// origin at the bottom left of the main screen) — the space every
        /// `frame(of:)` is in, so the two compare without conversion.
        @MainActor
        static var pointerLocation: CGPoint? {
            guard let eventClass = NSClassFromString("NSEvent") as? NSObject.Type,
                  let value = eventClass.value(forKey: "mouseLocation") as? NSValue
            else { return nil }
            var point = CGPoint.zero
            value.getValue(&point, size: MemoryLayout<CGPoint>.size)
            return point
        }

        /// The scene's window frame in AppKit's screen coordinates.
        @MainActor
        static func frame(of scene: UIWindowScene) -> CGRect? {
            guard let nsWindow = hostWindow(for: scene),
                  let value = nsWindow.value(forKey: "frame") as? NSValue
            else { return nil }
            var frame = CGRect.zero
            value.getValue(&frame, size: MemoryLayout<CGRect>.size)
            return frame
        }

        @MainActor
        static func location(of event: NSObject, in scene: UIWindowScene) -> CGPoint? {
            guard let nsWindow = hostWindow(for: scene),
                  (event.value(forKey: "window") as? NSObject) === nsWindow,
                  let locationValue = event.value(forKey: "locationInWindow") as? NSValue,
                  let frameValue = nsWindow.value(forKey: "frame") as? NSValue
            else { return nil }
            var location = CGPoint.zero
            locationValue.getValue(&location, size: MemoryLayout<CGPoint>.size)
            var frame = CGRect.zero
            frameValue.getValue(&frame, size: MemoryLayout<CGRect>.size)
            return CGPoint(
                x: location.x * pointsPerScreenPoint,
                y: (frame.height - location.y) * pointsPerScreenPoint,
            )
        }

        /// Whether `point` (screen coordinates) is over the top bar of a
        /// window with this frame — the band a tab is dropped on to join it.
        @MainActor
        static func barContains(_ point: CGPoint, inWindowFrame frame: CGRect) -> Bool {
            let barHeight = titleBarHeight / pointsPerScreenPoint
            return point.x >= frame.minX && point.x <= frame.maxX
                && point.y <= frame.maxY && point.y >= frame.maxY - barHeight
        }

        /// Moves the scene's window so its top-left corner sits at `point`
        /// (screen coordinates), kept below the menu bar by AppKit itself.
        @MainActor
        static func placeWindow(of scene: UIWindowScene, topLeft point: CGPoint) {
            guard let nsWindow = hostWindow(for: scene) else { return }
            typealias SetTopLeft = @convention(c) (AnyObject, Selector, CGPoint) -> Void
            let selector = NSSelectorFromString("setFrameTopLeftPoint:")
            guard nsWindow.responds(to: selector) else { return }
            let setTopLeft = unsafeBitCast(nsWindow.method(for: selector), to: SetTopLeft.self)
            setTopLeft(nsWindow, selector, point)
        }

        /// Screen points per UIKit point, for a distance measured in the
        /// app that has to land on the screen.
        @MainActor
        static func screenDistance(_ points: CGFloat) -> CGFloat {
            points / pointsPerScreenPoint
        }

        @MainActor
        private static func dress(_ nsWindow: NSObject) {
            clearTitlebarFill(in: nsWindow)
            positionWindowControls(in: nsWindow)
            keepTitlebarBandForContent(nsWindow)
        }

        /// The top bar sits in the band AppKit keeps for a title bar (the
        /// window's top ~30pt), and in a movable window AppKit moves the
        /// window from any drag that starts there — a chip pressed to be
        /// reordered took the window with it. A window that is not movable
        /// leaves those drags to the content. Bare chrome still moves it:
        /// `WindowDragRegion` makes the window movable for exactly the drag
        /// it starts (`dispatchTouchAsWindowMovement`) and takes that back
        /// when the drag ends. AppKit's own double-click on the band went
        /// with it, so `WindowDragRegion` answers that too.
        ///
        /// The band also keeps a *system* drag from reaching the content as
        /// a drop target — a tab lifted there was never offered to a slot,
        /// movable or not — which is why the strip reorders its chips with a
        /// plain gesture (`TabStripBar`) rather than a drag and drop.
        @MainActor
        private static func keepTitlebarBandForContent(_ nsWindow: NSObject) {
            guard nsWindow.responds(to: NSSelectorFromString("setMovable:")) else { return }
            nsWindow.setValue(false, forKey: "movable")
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
        /// AppKit drags no window that is not movable, and the window is
        /// kept that way (`keepTitlebarBandForContent`), so it is movable
        /// for this drag only — `endWindowMovement` puts it back.
        func dispatchTouchAsWindowMovement() {
            guard let window = currentEventWindow else { return }
            window.setValue(true, forKey: "movable")
            window.perform(NSSelectorFromString("performWindowDragWithEvent:"), with: currentEvent)
        }

        /// Ends what `dispatchTouchAsWindowMovement` started.
        func endWindowMovement() {
            currentEventWindow?.setValue(false, forKey: "movable")
        }

        /// A title bar's double-click: what System Settings ▸ Desktop & Dock
        /// says it does (`AppleActionOnDoubleClick`) — zoom unless that is
        /// Minimize or Do Nothing.
        func performTitlebarDoubleClick() {
            guard let window = currentEventWindow else { return }
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "None":
                return
            case "Minimize":
                window.perform(NSSelectorFromString("performMiniaturize:"), with: nil)
            default:
                window.perform(NSSelectorFromString("performZoom:"), with: nil)
            }
        }

        private var currentEvent: NSObject? {
            guard let appClass = NSClassFromString("NSApplication") as? NSObject.Type,
                  let app = appClass.value(forKey: "sharedApplication") as? NSObject
            else { return nil }
            return app.value(forKey: "currentEvent") as? NSObject
        }

        private var currentEventWindow: NSObject? {
            currentEvent?.value(forKey: "window") as? NSObject
        }
    }
#endif
