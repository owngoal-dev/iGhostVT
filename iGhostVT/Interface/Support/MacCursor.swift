//
//  MacCursor.swift
//  iGhostVT
//

#if targetEnvironment(macCatalyst)
    import Foundation

    enum MacCursor {
        case arrow
        case columnResize

        @MainActor
        func set() {
            guard let cursorClass = NSClassFromString("NSCursor") as? NSObject.Type,
                  let selector = selectors.first(where: { cursorClass.responds(to: $0) }),
                  let cursor = cursorClass.perform(selector)?.takeUnretainedValue() as? NSObject
            else { return }
            _ = cursor.perform(NSSelectorFromString("set"))
        }

        private var selectors: [Selector] {
            switch self {
            case .arrow:
                [NSSelectorFromString("arrowCursor")]
            case .columnResize:
                [NSSelectorFromString("columnResizeCursor"), NSSelectorFromString("resizeLeftRightCursor")]
            }
        }
    }
#endif
