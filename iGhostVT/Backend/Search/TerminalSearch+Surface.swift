//
//  TerminalSearch+Surface.swift
//  iGhostVT
//

import GhosttyTerminal
import ObjectiveC

@MainActor
private enum SearchAssociation {
    static let key = UnsafeRawPointer(UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1))
}

extension TerminalViewState {
    var search: TerminalSearch? {
        get { objc_getAssociatedObject(self, SearchAssociation.key) as? TerminalSearch }
        set { objc_setAssociatedObject(self, SearchAssociation.key, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
}

extension TerminalViewState: @retroactive TerminalSurfaceSearchDelegate {
    public func terminalDidStartSearch(needle: String?) {
        search?.present(needle: needle)
    }

    public func terminalDidEndSearch() {
        search?.dismiss()
    }

    public func terminalDidUpdateSearchTotal(_ total: Int?) {
        search?.surfaceDidReport(total: total)
    }

    public func terminalDidUpdateSearchSelected(_ selected: Int?) {
        search?.surfaceDidReport(selected: selected)
    }
}
