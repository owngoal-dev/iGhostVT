//
//  NewTabPicker.swift
//  iGhostVT
//

#if targetEnvironment(macCatalyst)
    import SwiftUI
    import UIKit

    /// The Mac's new-tab control: a popover in place of the menu.
    ///
    /// A menu gave every paired device a submenu, and a dozen devices made
    /// it taller than the window, each one's terminals a hover away and
    /// none of it searchable. The popover is a search field over two
    /// columns: where to look on the left — everywhere, this Mac, or one
    /// device, each with the number of terminals it holds — and what opens
    /// there on the right. It is a view, so unlike the menu it observes: a
    /// device that answers while it is open fills in, and nothing closes.
    ///
    /// Typing filters, ↑ and ↓ move the highlight, Return opens it, Tab
    /// moves down the left column and Escape closes. iOS keeps the menu.
    struct NewTabPicker: View {
        @ObservedObject var tabManager: TabManager
        /// Closes the popover; a row calls it before `onOpen`.
        let dismiss: () -> Void
        var onOpen: () -> Void = {}

        @ObservedObject private var recents = RecentDirectoryStore.shared
        @ObservedObject private var remoteHosts = RemoteHostDirectory.shared
        @ObservedObject private var remoteSessions = RemoteSessionCatalog.shared

        @State private var query = ""
        @State private var chosenScope = NewTabPickerContent.Scope.all
        @State private var highlightedID: String?
        /// The keyboard's last move of the highlight: the list scrolls to
        /// follow it, rows pass under a pointer that has not moved, and
        /// their hover would take the highlight straight back.
        @State private var keyboardMove = KeyboardMove(rowID: "", at: .distantPast)

        private struct KeyboardMove: Equatable {
            var rowID: String
            var at: Date
        }

        private static let scopeColumnWidth: CGFloat = 240
        private static let resultColumnWidth: CGFloat = 420
        /// As tall as what it lists, between these: a Mac with a device
        /// or two would otherwise open a mostly empty panel.
        private static let listHeights: ClosedRange<CGFloat> = 120 ... 400

        var body: some View {
            let choices = NewTabDirectoryChoices(
                tabManager: tabManager,
                recents: recents,
                remoteHosts: remoteHosts,
                remoteSessions: remoteSessions,
            )
            let content = NewTabPickerContent(choices: choices, tabManager: tabManager)
            let scopes = content.scopes
            // A device unpaired while its rows were up leaves its scope.
            let scope = scopes.contains { $0.scope == chosenScope } ? chosenScope : .all
            let pane = content.pane(for: scope, query: query)
            let rows = pane.sections.flatMap(\.rows).filter(\.isEnabled)
            let highlighted = rows.first { $0.id == highlightedID } ?? rows.first

            VStack(spacing: 0) {
                HStack(spacing: DS.Padding.s) {
                    Image(systemName: "magnifyingglass")
                        .font(DS.Font.body)
                        .foregroundColor(.secondary)
                        .accessibilityHidden(true)
                    NewTabSearchField(
                        text: $query,
                        placeholder: String(
                            localized: "Search",
                            comment: "Placeholder of the search field over the Mac's new-tab popover",
                        ),
                        onMove: { step in move(by: step, in: rows, from: highlighted) },
                        onSubmit: {
                            if let highlighted { perform(highlighted) }
                        },
                        onCycleScope: { step in cycleScope(by: step, in: scopes, from: scope) },
                        onCancel: dismiss,
                    )
                }
                .padding(.horizontal, DS.Padding.l)
                .frame(height: 44)

                Divider()

                HStack(spacing: 0) {
                    // One place to look is no choice: without a paired
                    // device the popover is the list alone.
                    if scopes.count > 1 {
                        scopeColumn(scopes, selected: scope)
                            .frame(width: Self.scopeColumnWidth)
                        Divider()
                    }
                    resultColumn(pane, highlighted: highlighted)
                        .frame(width: Self.resultColumnWidth)
                }
            }
            // Sized by the left column and the first page, never by the
            // page showing, so the panel keeps its size from page to page
            // and while a search narrows it.
            .frame(height: 45 + min(max(content.restingListHeight, Self.listHeights.lowerBound), Self.listHeights.upperBound))
            .onAppear { NewTabMenuElements.askRemoteDevices() }
        }

        // MARK: - Columns

        private func scopeColumn(_ scopes: [NewTabPickerContent.ScopeItem], selected: NewTabPickerContent.Scope) -> some View {
            // No scroll bar: with a mouse attached the Mac draws one that
            // stays, over the counts at the rows' trailing ends.
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(scopes) { item in
                        if item.startsDevices {
                            NewTabPickerHeader(title: String(localized: "Other Devices"))
                        }
                        Button {
                            chosenScope = item.scope
                            highlightedID = nil
                        } label: {
                            NewTabScopeRow(item: item, isSelected: item.scope == selected)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(item.scope == selected ? [.isSelected] : [])
                    }
                }
                .padding(DS.Padding.s)
            }
        }

        private func resultColumn(_ pane: NewTabPickerContent.Pane, highlighted: NewTabPickerContent.Row?) -> some View {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(pane.sections) { section in
                            if let title = section.title {
                                NewTabPickerHeader(title: title)
                            }
                            ForEach(section.rows) { row in
                                Button {
                                    perform(row)
                                } label: {
                                    NewTabPickerRow(row: row, isHighlighted: row.id == highlighted?.id)
                                }
                                .buttonStyle(.plain)
                                .disabled(!row.isEnabled)
                                .onHover { isInside in
                                    guard isInside, row.isEnabled,
                                          Date().timeIntervalSince(keyboardMove.at) > 0.3
                                    else { return }
                                    highlightedID = row.id
                                }
                                .id(row.id)
                            }
                        }
                        if let note = pane.note {
                            Text(verbatim: note)
                                .font(DS.Font.label)
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: pane.sections.isEmpty ? .center : .leading)
                                .padding(.horizontal, DS.Padding.m)
                                .padding(.vertical, pane.sections.isEmpty ? DS.Padding.xl : DS.Padding.s)
                        }
                    }
                    .padding(DS.Padding.s)
                    // Room for that scroll bar beside the rows, not on
                    // them.
                    .padding(.trailing, DS.Padding.s)
                }
                .onChange(of: keyboardMove) { move in
                    proxy.scrollTo(move.rowID)
                }
            }
        }

        // MARK: - Actions

        private func move(by step: Int, in rows: [NewTabPickerContent.Row], from current: NewTabPickerContent.Row?) {
            guard !rows.isEmpty else { return }
            let index = current.flatMap { current in rows.firstIndex { $0.id == current.id } }
            let next = index.map { min(max($0 + step, 0), rows.count - 1) } ?? 0
            highlightedID = rows[next].id
            keyboardMove = KeyboardMove(rowID: rows[next].id, at: Date())
        }

        private func cycleScope(
            by step: Int,
            in scopes: [NewTabPickerContent.ScopeItem],
            from current: NewTabPickerContent.Scope,
        ) {
            guard scopes.count > 1, let index = scopes.firstIndex(where: { $0.scope == current }) else { return }
            chosenScope = scopes[(index + step + scopes.count) % scopes.count].scope
            highlightedID = nil
        }

        private func perform(_ row: NewTabPickerContent.Row) {
            guard row.isEnabled else { return }
            dismiss()
            switch row.action {
            case let .open(origin):
                tabManager.newTab(origin)
            case let .attach(hostID, sessionIDs):
                for sessionID in sessionIDs {
                    tabManager.openRemoteTab(attachingTo: sessionID, hostID: hostID)
                }
            }
            onOpen()
        }
    }

    // MARK: - Content

    /// What the popover lists, worked out from the same choices the menu
    /// is built from: the places to look, and the rows for one of them.
    @MainActor
    struct NewTabPickerContent {
        enum Scope: Hashable {
            case all
            case local
            case host(String)
        }

        struct ScopeItem: Identifiable {
            var scope: Scope
            var title: String
            var symbol: String
            /// The terminals a device holds, once it has said; nil for
            /// none, and for a scope that is not one device.
            var count: Int?
            /// Why a device has no count: still connecting, out of reach,
            /// on another version.
            var status: String?
            var isAvailable = true
            /// The first device, which the column's header goes above.
            var startsDevices = false

            var id: Scope {
                scope
            }
        }

        struct Row: Identifiable {
            enum Action {
                case open(TabManager.Origin)
                /// Opens here each of these terminals a device holds.
                case attach(hostID: String, sessionIDs: [UInt64])
            }

            var id: String
            var title: String
            /// The dim text at the row's trailing end: where a directory
            /// is, where a terminal sits.
            var detail: String?
            var symbol: String
            /// A terminal already open in this window.
            var isOpenHere = false
            var isEnabled = true
            var action: Action
            /// More to match a search against than the row shows.
            var keywords: [String] = []
        }

        struct Section: Identifiable {
            var id: String
            var title: String?
            var rows: [Row]
        }

        struct Pane {
            var sections: [Section]
            /// A line under the rows, or alone in their place: what a
            /// device has not said yet, or that nothing matched.
            var note: String?
        }

        let choices: NewTabDirectoryChoices
        let tabManager: TabManager

        /// With this many devices or fewer there is no left column: one
        /// list holds this Mac and each device whole, under its name. Two
        /// columns for a single device were a panel that was mostly
        /// empty.
        private static let singleListDeviceLimit = 2

        private var isSingleList: Bool {
            choices.remoteHosts.count <= Self.singleListDeviceLimit
        }

        /// The height of the lists as the popover opens — the left column
        /// or the first page, whichever is taller.
        var restingListHeight: CGFloat {
            let row: CGFloat = 34
            let header: CGFloat = 36
            let padding = DS.Padding.s * 2
            let scopes = scopes
            let column = scopes.count > 1 ? CGFloat(scopes.count) * row + header : 0
            let pane = pane(for: .all, query: "")
            let page = pane.sections.reduce(0) { height, section in
                height + CGFloat(section.rows.count) * row + (section.title == nil ? 0 : header)
            }
            return max(column, page) + padding
        }

        var scopes: [ScopeItem] {
            guard !isSingleList else {
                return [ScopeItem(scope: .all, title: "", symbol: "desktopcomputer")]
            }
            var items = [
                ScopeItem(
                    scope: .all,
                    title: String(
                        localized: "All Devices",
                        comment: "New-tab popover on the Mac: the choice that lists this Mac and every paired device together",
                    ),
                    symbol: "square.grid.2x2",
                ),
                ScopeItem(
                    scope: .local,
                    title: String(
                        localized: "This Mac",
                        comment: "New-tab popover on the Mac: the choice that lists only this Mac's directories",
                    ),
                    symbol: "desktopcomputer",
                ),
            ]
            for (index, host) in choices.remoteHosts.enumerated() {
                var item = ScopeItem(scope: .host(host.id), title: host.displayName, symbol: "network")
                item.startsDevices = index == 0
                if let unavailable = unavailableText(host) {
                    item.status = unavailable
                    item.isAvailable = false
                } else {
                    switch listing(of: host) {
                    case let .listed(sessions):
                        item.count = sessions.isEmpty ? nil : sessions.count
                    case let other:
                        item.status = RemoteSessionCatalog.statusText(other)
                    }
                }
                items.append(item)
            }
            return items
        }

        func pane(for scope: Scope, query: String) -> Pane {
            let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
            let isSearching = !words.isEmpty
            var sections: [Section] = []
            var note: String?
            switch scope {
            case .local:
                sections = localSections
            case .all:
                sections = localSections
                for host in choices.remoteHosts {
                    // Everywhere at once is what is running everywhere: a
                    // device's fresh shell and its old directories are its
                    // own page's, and a search's — or this page's, when it
                    // is the only one.
                    var rows: [Row] = []
                    if let unavailable = unavailableText(host) {
                        if isSingleList { rows = [statusRow(unavailable, on: host)] }
                    } else if isSingleList {
                        rows = self.rows(on: host)
                        if let status = RemoteSessionCatalog.statusText(listing(of: host)) {
                            rows.append(statusRow(status, on: host))
                        }
                    } else {
                        rows = isSearching ? self.rows(on: host) : sessionRows(on: host)
                    }
                    sections.append(Section(id: "host:\(host.id)", title: host.displayName, rows: rows))
                }
            case let .host(hostID):
                guard let host = choices.remoteHosts.first(where: { $0.id == hostID }) else { break }
                if let unavailable = unavailableText(host) {
                    return Pane(sections: [], note: unavailable)
                }
                sections = hostSections(host)
                note = RemoteSessionCatalog.statusText(listing(of: host))
            }
            if isSearching {
                sections = sections.map { section in
                    var section = section
                    section.rows = section.rows.filter { row in
                        // A greyed row is a status, not a place to go.
                        guard row.isEnabled else { return false }
                        let text = ([row.title, row.detail ?? "", section.title ?? ""] + row.keywords).joined(separator: "\n")
                        return words.allSatisfy { text.localizedStandardContains($0) }
                    }
                    return section
                }
            }
            sections.removeAll { $0.rows.isEmpty }
            if isSearching, sections.isEmpty {
                note = String(
                    localized: "No Results",
                    comment: "New-tab popover on the Mac: nothing matches what was typed in the search field",
                )
            }
            return Pane(sections: sections, note: note)
        }

        // MARK: This Mac

        /// The menu's three groups: the home, where this window's tabs
        /// are, where sessions have been.
        private var localSections: [Section] {
            guard !AppEdition.isRemoteOnly else { return [] }
            let home = Row(
                id: "home",
                title: String(
                    localized: "Home (directory)",
                    comment: "Menu item: opens a terminal in the home directory; the English text is “Home”",
                ),
                detail: "~",
                symbol: "house",
                action: .open(.home),
            )
            let open = choices.openTabs.map { tab in
                // By its session, as the menu's row is: the daemon reads
                // the directory again as the tab opens.
                directoryRow(
                    id: "tab:\(tab.sessionID)",
                    tab.directory,
                    symbol: "macwindow",
                    action: .open(.session(tab.sessionID)),
                )
            }
            let recent = choices.recents.map { directory in
                directoryRow(id: "dir:\(directory.path)", directory, symbol: "clock", action: .open(.directory(directory)))
            }
            return [
                Section(id: "home", title: nil, rows: [home]),
                Section(id: "tabs", title: String(localized: "Open Tabs"), rows: open),
                Section(id: "recent", title: String(localized: "Recent"), rows: recent),
            ]
        }

        /// A directory by its folder's name, with the whole spelling
        /// beside it: two folders of one name are told apart at a glance,
        /// which the menu's bare names never were.
        private func directoryRow(id: String, _ directory: TerminalDirectory, symbol: String, action: Row.Action) -> Row {
            Row(
                id: id,
                title: directory.name,
                detail: directory.label == directory.name ? nil : directory.label,
                symbol: symbol,
                action: action,
            )
        }

        // MARK: A paired device

        /// A device's own page, in the menu's order: a fresh shell and
        /// Open All, its terminals, the directories tabs here were in.
        private func hostSections(_ host: PairedRemoteHost) -> [Section] {
            var actions = [freshRow(on: host)]
            let sessions = sessions(on: host)
            if !sessions.isEmpty {
                let closed = sessions.filter { !isOpenHere($0, on: host) }
                actions.append(Row(
                    id: "all:\(host.id)",
                    title: String(localized: "Open All"),
                    symbol: "square.stack",
                    isEnabled: !closed.isEmpty,
                    action: .attach(hostID: host.id, sessionIDs: closed.map(\.id)),
                ))
            }
            return [
                Section(id: "actions:\(host.id)", title: nil, rows: actions),
                Section(id: "sessions:\(host.id)", title: String(localized: "Open Terminals"), rows: sessionRows(on: host)),
                Section(id: "recent:\(host.id)", title: String(localized: "Recent"), rows: recentRows(on: host)),
            ]
        }

        /// Everything a device offers as one group under its name, for a
        /// search across all of them.
        private func rows(on host: PairedRemoteHost) -> [Row] {
            [freshRow(on: host)] + sessionRows(on: host) + recentRows(on: host)
        }

        /// What a device has not said, as a row nothing opens: the single
        /// list has no page of the device's own to say it on.
        private func statusRow(_ status: String, on host: PairedRemoteHost) -> Row {
            Row(
                id: "status:\(host.id)",
                title: status,
                symbol: "ellipsis",
                isEnabled: false,
                action: .attach(hostID: host.id, sessionIDs: []),
            )
        }

        private func freshRow(on host: PairedRemoteHost) -> Row {
            Row(
                id: "new:\(host.id)",
                title: String(localized: "New Terminal", comment: "Menu item: a fresh shell on another device"),
                symbol: "plus",
                action: .open(.remote(hostID: host.id)),
                keywords: [host.displayName],
            )
        }

        private func sessionRows(on host: PairedRemoteHost) -> [Row] {
            sessions(on: host).map { session in
                // A terminal titled by its directory already says where.
                let place = session.directory?.name
                return Row(
                    id: "session:\(host.id):\(session.id)",
                    title: session.menuTitle,
                    detail: place == session.menuTitle ? nil : place,
                    symbol: "terminal",
                    isOpenHere: isOpenHere(session, on: host),
                    action: .attach(hostID: host.id, sessionIDs: [session.id]),
                    keywords: [host.displayName, session.processName ?? "", session.directory?.label ?? ""],
                )
            }
        }

        private func recentRows(on host: PairedRemoteHost) -> [Row] {
            (choices.remoteRecents[host.id] ?? []).map { directory in
                var row = directoryRow(
                    id: "recent:\(host.id):\(directory.path)",
                    directory,
                    symbol: "clock",
                    action: .open(.remote(hostID: host.id, directory: directory)),
                )
                row.keywords = [host.displayName]
                return row
            }
        }

        private func listing(of host: PairedRemoteHost) -> RemoteSessionCatalog.Listing {
            choices.remoteListings[host.id] ?? .loading
        }

        private func sessions(on host: PairedRemoteHost) -> [XPCDaemonTransport.SessionSummary] {
            if case let .listed(rows) = listing(of: host) { rows } else { [] }
        }

        private func isOpenHere(_ session: XPCDaemonTransport.SessionSummary, on host: PairedRemoteHost) -> Bool {
            tabManager.tabs.contains { $0.remoteHostID == host.id && $0.remoteSessionID == session.id }
        }

        /// Another iGhostVT there, or nothing can reach it: nothing opens
        /// on it, and its page says why.
        private func unavailableText(_ host: PairedRemoteHost) -> String? {
            if let theirs = RemoteHostDirectory.mismatchedVersion(ofHostID: host.id) {
                return RemoteVersionText.needsUpdate(theirs: theirs)
            }
            if listing(of: host) == .unreachable {
                return RemoteSessionCatalog.statusText(.unreachable)
            }
            return nil
        }
    }

    // MARK: - Rows

    private struct NewTabPickerHeader: View {
        let title: String

        var body: some View {
            Text(verbatim: title)
                .font(DS.Font.captionEmphasis)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .padding(.horizontal, DS.Padding.m)
                .padding(.top, DS.Padding.m)
                .padding(.bottom, DS.Padding.xs)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private struct NewTabScopeRow: View {
        let item: NewTabPickerContent.ScopeItem
        let isSelected: Bool

        var body: some View {
            HStack(spacing: DS.Padding.s) {
                Image(systemName: item.symbol)
                    .font(DS.Font.label)
                    .frame(width: 20)
                Text(verbatim: item.title)
                    .font(isSelected ? DS.Font.labelEmphasis : DS.Font.label)
                    .lineLimit(1)
                Spacer(minLength: DS.Padding.xs)
                if let count = item.count {
                    Text(verbatim: "\(count)")
                        .font(DS.Font.caption)
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
            }
            .foregroundColor(item.isAvailable ? .primary : .secondary)
            .padding(.horizontal, DS.Padding.m)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                    .fill(isSelected ? Color.primary.opacity(0.12) : Color.clear),
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: item.title))
            .accessibilityValue(Text(verbatim: item.count.map { "\($0)" } ?? item.status ?? ""))
        }
    }

    private struct NewTabPickerRow: View {
        let row: NewTabPickerContent.Row
        let isHighlighted: Bool

        var body: some View {
            HStack(spacing: DS.Padding.s) {
                Image(systemName: row.symbol)
                    .font(DS.Font.label)
                    .foregroundColor(.secondary)
                    .frame(width: 20)
                Text(verbatim: row.title)
                    .font(DS.Font.label)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: DS.Padding.s)
                if let detail = row.detail {
                    // The end of a path is the part that tells two apart.
                    Text(verbatim: detail)
                        .font(DS.Font.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                if row.isOpenHere {
                    Image(systemName: "checkmark")
                        .font(DS.Font.captionEmphasis)
                        .foregroundColor(.accentColor)
                        .accessibilityLabel("Already Open in This Window")
                }
            }
            .opacity(row.isEnabled ? 1 : 0.4)
            .padding(.horizontal, DS.Padding.m)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                    .fill(isHighlighted ? Color.primary.opacity(0.12) : Color.clear),
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous))
        }
    }

    // MARK: - Search field

    /// The popover's one text field, in UIKit for its keys: it takes the
    /// keyboard as it appears, and ↑ ↓ Tab and Escape drive the lists
    /// while the caret stays where it is — SwiftUI's key handling for a
    /// field begins at Catalyst 17, above this app's floor.
    private struct NewTabSearchField: UIViewRepresentable {
        @Binding var text: String
        let placeholder: String
        let onMove: (Int) -> Void
        let onSubmit: () -> Void
        let onCycleScope: (Int) -> Void
        let onCancel: () -> Void
        @Environment(\.interfaceTextScale) private var scale

        func makeUIView(context: Context) -> Field {
            let field = Field(frame: .zero)
            field.borderStyle = .none
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.spellCheckingType = .no
            field.returnKeyType = .go
            field.focusEffect = nil
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            field.delegate = context.coordinator
            field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
            return field
        }

        func updateUIView(_ field: Field, context: Context) {
            context.coordinator.parent = self
            field.owner = context.coordinator
            if field.text != text {
                field.text = text
            }
            field.placeholder = placeholder
            field.font = .systemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize * scale)
        }

        func makeCoordinator() -> Coordinator {
            Coordinator(parent: self)
        }

        final class Coordinator: NSObject, UITextFieldDelegate {
            var parent: NewTabSearchField

            init(parent: NewTabSearchField) {
                self.parent = parent
            }

            @objc func changed(_ field: UITextField) {
                parent.text = field.text ?? ""
            }

            func textFieldShouldReturn(_: UITextField) -> Bool {
                parent.onSubmit()
                return false
            }
        }

        final class Field: UITextField {
            weak var owner: Coordinator?

            override func didMoveToWindow() {
                super.didMoveToWindow()
                guard window != nil else { return }
                // Once the popover is on screen: a field asked earlier is
                // refused, its window not yet key.
                DispatchQueue.main.async { [weak self] in
                    _ = self?.becomeFirstResponder()
                }
            }

            /// None while an input method is composing: the arrows, Tab
            /// and Escape are its own then, to walk and dismiss its
            /// candidates.
            override var keyCommands: [UIKeyCommand]? {
                guard markedTextRange == nil else { return [] }
                return [
                    command(UIKeyCommand.inputUpArrow, [], #selector(moveUp(_:))),
                    command(UIKeyCommand.inputDownArrow, [], #selector(moveDown(_:))),
                    command("\t", [], #selector(nextScope(_:))),
                    command("\t", .shift, #selector(previousScope(_:))),
                    command(UIKeyCommand.inputEscape, [], #selector(cancel(_:))),
                ]
            }

            private func command(_ input: String, _ modifiers: UIKeyModifierFlags, _ action: Selector) -> UIKeyCommand {
                let command = UIKeyCommand(input: input, modifierFlags: modifiers, action: action)
                command.wantsPriorityOverSystemBehavior = true
                return command
            }

            @objc private func moveUp(_: Any?) {
                owner?.parent.onMove(-1)
            }

            @objc private func moveDown(_: Any?) {
                owner?.parent.onMove(1)
            }

            @objc private func nextScope(_: Any?) {
                owner?.parent.onCycleScope(1)
            }

            @objc private func previousScope(_: Any?) {
                owner?.parent.onCycleScope(-1)
            }

            @objc private func cancel(_: Any?) {
                owner?.parent.onCancel()
            }
        }
    }

    // MARK: - Presentation

    extension View {
        /// The Mac's new-tab popover, pointing at this view.
        func newTabPicker(
            isPresented: Binding<Bool>,
            tabManager: TabManager,
            arrowEdge: Edge = .top,
            onOpen: @escaping () -> Void = {},
        ) -> some View {
            popover(isPresented: isPresented, arrowEdge: arrowEdge) {
                NewTabPicker(
                    tabManager: tabManager,
                    dismiss: { isPresented.wrappedValue = false },
                    onOpen: onOpen,
                )
                .keepsNewTabPopover()
            }
        }
    }

    private extension View {
        /// A window narrow enough to read as compact would turn the
        /// popover into a sheet.
        @ViewBuilder
        func keepsNewTabPopover() -> some View {
            if #available(macCatalyst 16.4, *) {
                presentationCompactAdaptation(.popover)
            } else {
                self
            }
        }
    }
#endif
