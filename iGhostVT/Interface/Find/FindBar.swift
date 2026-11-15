//
//  FindBar.swift
//  iGhostVT
//

import Combine
import SwiftUI
import UIKit

enum FindDockPlacement: Equatable {
    case inset(keyboardOverlap: CGFloat)
    case floating(columnWidth: CGFloat)

    var isFloating: Bool {
        if case .floating = self { true } else { false }
    }
}

struct FindDock: View {
    @ObservedObject var search: TerminalSearch
    let placement: FindDockPlacement

    private static let controlSize: CGFloat = 44
    private static let floatingWidthShare: CGFloat = 0.6
    private static let floatingWidthRange: ClosedRange<CGFloat> = 560 ... 840

    var body: some View {
        ZStack {
            if search.isPresented {
                placed
                    .buttonStyle(.borderless)
                    .foregroundColor(.primary)
                    .transition(.opacity)
            }
        }
        .animation(placement.isFloating ? DS.Motion.snappy : nil, value: search.isPresented)
    }

    @ViewBuilder
    private var placed: some View {
        switch placement {
        case let .inset(keyboardOverlap):
            VStack(spacing: 0) {
                controls
                    .padding(.horizontal, DS.Padding.l)
                    .padding(.top, DS.Padding.s)
                    .bottomScreenMargin(
                        keyboardOverlap > 0 ? DS.Padding.s : DS.Padding.xs,
                        minimum: keyboardOverlap > 0 ? 0 : DS.Padding.l,
                    )
                Color.clear
                    .frame(height: keyboardOverlap)
            }
        case let .floating(columnWidth):
            controls
                .frame(maxWidth: Self.floatingWidth(in: columnWidth))
                .padding(.horizontal, DS.Padding.l)
                .padding(.bottom, DS.Padding.m)
        }
    }

    private static func floatingWidth(in columnWidth: CGFloat) -> CGFloat {
        let share = columnWidth * floatingWidthShare
        return min(max(share, floatingWidthRange.lowerBound), floatingWidthRange.upperBound)
    }

    private var controls: some View {
        GlassBarContainer(spacing: DS.Padding.s) {
            HStack(spacing: DS.Padding.s) {
                Button(action: search.dismiss) {
                    Image(systemName: "xmark")
                        .font(DS.Font.control)
                        .frame(width: Self.controlSize, height: Self.controlSize)
                        .contentShape(Circle())
                        .barGlass(in: Circle())
                }
                .accessibilityLabel("Close")
                HStack(spacing: 0) {
                    FindHistoryMenu(search: search)
                        .frame(height: Self.controlSize)
                    FindField(search: search)
                        .frame(height: Self.controlSize)
                    FindStatus(search: search)
                }
                .padding(.trailing, DS.Padding.s)
                .barGlass(in: Capsule(), interactive: false)
                HStack(spacing: 0) {
                    FindStepper(search: search, controlSize: Self.controlSize - DS.Padding.xs)
                }
                .frame(height: Self.controlSize)
                .padding(.horizontal, DS.Padding.xs)
                .barGlass(in: Capsule(), interactive: false)
            }
        }
    }
}

struct HiddenWhileFinding: ViewModifier {
    let search: TerminalSearch?
    @State private var isFinding = false

    func body(content: Content) -> some View {
        content
            .opacity(isFinding ? 0 : 1)
            .allowsHitTesting(!isFinding)
            .accessibilityHidden(isFinding)
            .onReceive(presence) { isFinding = $0 }
    }

    private var presence: AnyPublisher<Bool, Never> {
        search?.$isPresented.eraseToAnyPublisher() ?? Just(false).eraseToAnyPublisher()
    }
}

private struct FindHistoryMenu: View {
    let search: TerminalSearch
    @ObservedObject private var history = FindHistory.shared

    var body: some View {
        Menu {
            if history.queries.isEmpty {
                Button("No Recent Searches") {}
                    .disabled(true)
            } else {
                Section("Recent Searches") {
                    ForEach(history.queries, id: \.self) { query in
                        Button(query) { search.search(for: query) }
                    }
                }
                Button(role: .destructive, action: history.removeAll) {
                    Label("Clear Recent Searches", systemImage: "trash")
                }
            }
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "magnifyingglass")
                    .font(DS.Font.label)
                Image(systemName: "chevron.down")
                    .font(DS.Font.captionEmphasis)
                    .imageScale(.small)
                    .foregroundColor(.secondary)
            }
            .padding(.leading, DS.Padding.m)
            .padding(.trailing, DS.Padding.s)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel("Recent Searches")
    }
}

private struct FindStatus: View {
    @ObservedObject var search: TerminalSearch

    var body: some View {
        if let text {
            Text(text)
                .font(DS.Font.caption)
                .foregroundColor(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, DS.Padding.xs)
        }
    }

    private var text: String? {
        if search.showsNoResults {
            return String(localized: "No Results")
        }
        guard let total = search.total, total > 0 else { return nil }
        guard let selected = search.selected else { return "\(total)" }
        return "\(selected + 1)/\(total)"
    }
}

private struct FindStepper: View {
    @ObservedObject var search: TerminalSearch
    let controlSize: CGFloat

    var body: some View {
        Group {
            FindBarButton(symbol: "chevron.up", label: "Find Next", size: controlSize) {
                search.navigate(.older)
            }
            FindBarButton(symbol: "chevron.down", label: "Find Previous", size: controlSize) {
                search.navigate(.newer)
            }
        }
        .disabled(search.query.isEmpty)
    }
}

private struct FindBarButton: View {
    let symbol: String
    let label: LocalizedStringKey
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(DS.Font.label)
                .frame(width: size, height: size)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
    }
}
