//
//  MiddleClick.swift
//  iGhostVT
//

import SwiftUI
import UIKit

extension View {
    func onMiddleClick(perform action: @escaping () -> Void) -> some View {
        background(MiddleClickReader(action: action))
    }
}

private struct MiddleClickReader: UIViewRepresentable {
    let action: () -> Void

    func makeUIView(context _: Context) -> MiddleClickReaderView {
        MiddleClickReaderView()
    }

    func updateUIView(_ view: MiddleClickReaderView, context _: Context) {
        view.action = action
    }
}

private final class MiddleClickReaderView: UIView, UIGestureRecognizerDelegate {
    var action: () -> Void = {}

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func isClicked(at point: CGPoint, hitting touched: UIView?) -> Bool {
        bounds.contains(point) && isShowing(point) && sharesContainer(with: touched)
    }

    private func isShowing(_ point: CGPoint) -> Bool {
        var ancestor = superview
        while let view = ancestor {
            if view.clipsToBounds || view is UIScrollView, !view.bounds.contains(convert(point, to: view)) {
                return false
            }
            ancestor = view.superview
        }
        return true
    }

    private func sharesContainer(with touched: UIView?) -> Bool {
        guard let touched, let container = containerUnderWindow else { return true }
        return touched.isDescendant(of: container)
    }

    private var containerUnderWindow: UIView? {
        var view: UIView = self
        while let parent = view.superview, !(parent is UIWindow) {
            view = parent
        }
        return view.superview is UIWindow ? view : nil
    }

    #if targetEnvironment(macCatalyst)
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil {
                MacMiddleClickMonitor.remove(self)
            } else {
                MacMiddleClickMonitor.add(self)
            }
        }
    #else
        private static let middleButton = UIEvent.ButtonMask.button(3)

        private lazy var recognizer: UITapGestureRecognizer = {
            let recognizer = UITapGestureRecognizer(target: self, action: #selector(clicked))
            recognizer.buttonMaskRequired = Self.middleButton
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = self
            return recognizer
        }()

        override func willMove(toWindow newWindow: UIWindow?) {
            super.willMove(toWindow: newWindow)
            window?.removeGestureRecognizer(recognizer)
            newWindow?.addGestureRecognizer(recognizer)
        }

        func gestureRecognizer(_: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            isClicked(at: touch.location(in: self), hitting: touch.view)
        }

        func gestureRecognizer(
            _: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer,
        ) -> Bool {
            true
        }

        @objc private func clicked() {
            action()
        }
    #endif
}

#if targetEnvironment(macCatalyst)
    @MainActor
    private enum MacMiddleClickMonitor {
        private static let readers = NSHashTable<MiddleClickReaderView>.weakObjects()
        private static var monitor: AnyObject?
        private static weak var pressed: MiddleClickReaderView?

        private static let otherMouseDown = 25
        private static let otherMouseUp = 26
        private static let middleButtonNumber = 2

        static func add(_ reader: MiddleClickReaderView) {
            readers.add(reader)
            install()
        }

        static func remove(_ reader: MiddleClickReaderView) {
            readers.remove(reader)
        }

        private static func install() {
            let selector = NSSelectorFromString("addLocalMonitorForEventsMatchingMask:handler:")
            guard monitor == nil,
                  let eventClass = NSClassFromString("NSEvent"),
                  let method = class_getClassMethod(eventClass, selector)
            else { return }
            typealias Handler = @convention(block) (NSObject) -> NSObject?
            typealias AddMonitor = @convention(c) (AnyClass, Selector, UInt64, Handler) -> AnyObject?
            let handler: Handler = { event in
                MainActor.assumeIsolated { handle(event) }
                return event
            }
            let mask: UInt64 = 1 << otherMouseDown | 1 << otherMouseUp
            monitor = unsafeBitCast(method_getImplementation(method), to: AddMonitor.self)(eventClass, selector, mask, handler)
        }

        private static func handle(_ event: NSObject) {
            guard event.value(forKey: "buttonNumber") as? Int == middleButtonNumber,
                  let type = event.value(forKey: "type") as? Int
            else { return }
            let reader = reader(under: event)
            if type == otherMouseDown {
                pressed = reader
            } else if type == otherMouseUp {
                if let reader, reader === pressed {
                    reader.action()
                }
                pressed = nil
            }
        }

        private static func reader(under event: NSObject) -> MiddleClickReaderView? {
            readers.allObjects.first { reader in
                guard let window = reader.window, let scene = window.windowScene,
                      let point = CatalystWindowChrome.location(of: event, in: scene)
                else { return false }
                return reader.isClicked(at: reader.convert(point, from: nil), hitting: window.hitTest(point, with: nil))
            }
        }
    }
#endif
