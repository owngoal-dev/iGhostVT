//
//  FindField.swift
//  iGhostVT
//

import SwiftUI
import UIKit

struct FindField: UIViewRepresentable {
    @ObservedObject var search: TerminalSearch
    @Environment(\.interfaceTextScale) private var scale

    func makeUIView(context: Context) -> Field {
        let field = Field(frame: .zero)
        field.borderStyle = .none
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartDashesType = .no
        field.smartQuotesType = .no
        field.smartInsertDeleteType = .no
        if #available(iOS 17.0, *) {
            field.inlinePredictionType = .no
        }
        field.returnKeyType = .search
        field.enablesReturnKeyAutomatically = true
        field.clearButtonMode = .whileEditing
        field.focusEffect = nil
        field.placeholder = String(localized: "Find (field)")
        field.accessibilityLabel = String(localized: "Find (field)")
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.delegate = context.coordinator
        field.owner = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        return field
    }

    func updateUIView(_ field: Field, context: Context) {
        let coordinator = context.coordinator
        coordinator.search = search
        field.font = .systemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize * scale)
        if field.markedTextRange == nil, field.text != search.query {
            field.text = search.query
        }
        if search.takeFieldFocusRequest() {
            field.takeFocus()
        }
    }

    static func dismantleUIView(_ field: Field, coordinator: Coordinator) {
        coordinator.search.isEditing = false
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(search: search)
    }

    @MainActor
    final class Coordinator: NSObject, UITextFieldDelegate {
        var search: TerminalSearch

        init(search: TerminalSearch) {
            self.search = search
        }

        @objc func changed(_ field: UITextField) {
            guard field.markedTextRange == nil else { return }
            search.edit(field.text ?? "")
        }

        func textFieldDidBeginEditing(_: UITextField) {
            search.isEditing = true
        }

        func textFieldDidEndEditing(_: UITextField) {
            search.isEditing = false
        }

        func textFieldShouldReturn(_: UITextField) -> Bool {
            search.navigate(.older)
            return false
        }
    }

    final class Field: UITextField {
        weak var owner: Coordinator?
        private var wantsFocus = false

        func takeFocus() {
            guard window != nil else {
                wantsFocus = true
                return
            }
            wantsFocus = false
            DispatchQueue.main.async { [weak self] in
                guard let self, window != nil, becomeFirstResponder() else { return }
                selectedTextRange = textRange(from: beginningOfDocument, to: endOfDocument)
            }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil, wantsFocus {
                takeFocus()
            }
        }

        override var keyCommands: [UIKeyCommand]? {
            guard markedTextRange == nil else { return [] }
            return [
                command("\r", .shift, #selector(findNewer(_:))),
                command(UIKeyCommand.inputEscape, [], #selector(cancel(_:))),
            ]
        }

        private func command(_ input: String, _ modifiers: UIKeyModifierFlags, _ action: Selector) -> UIKeyCommand {
            let command = UIKeyCommand(input: input, modifierFlags: modifiers, action: action)
            command.wantsPriorityOverSystemBehavior = true
            return command
        }

        @objc private func findNewer(_: Any?) {
            owner?.search.navigate(.newer)
        }

        @objc private func cancel(_: Any?) {
            owner?.search.dismiss()
        }
    }
}
