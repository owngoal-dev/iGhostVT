//
//  LicensesView.swift
//  iGhostVT
//

import SwiftUI

/// One license the app ships under: the app's own, Ghostty's, and one per
/// package the build linked — a row in `Licenses.json`, which
/// `Scripts/collect-licenses.py` writes into the bundle at build time.
struct LicenseEntry: Decodable, Identifiable {
    let name: String
    let version: String?
    /// A short identifier ("MIT", "Apache-2.0") the collector read off the
    /// text; "Other" when it recognised none.
    let license: String
    let url: String
    let text: String

    var id: String {
        "\(name)@\(version ?? "")"
    }

    var homepage: URL? {
        url.isEmpty ? nil : URL(string: url)
    }

    var licenseName: String {
        switch license {
        case "MIT": String(localized: "MIT License")
        case "Apache-2.0": String(localized: "Apache 2.0")
        default: license
        }
    }

    /// "MIT · 1.5.1" — the identifier, then the version when there is one.
    var summary: String {
        [license, version].compactMap(\.self).joined(separator: " · ")
    }

    /// `summary` for a list row: a commit pin (Ghostty is versioned by
    /// one) shortened to the seven characters git itself abbreviates to, so
    /// one row's forty hex digits do not set it apart from the rest. The
    /// license's own page keeps the full commit.
    var shortSummary: String {
        guard let version,
              version.count == 40,
              version.allSatisfy(\.isHexDigit)
        else { return summary }
        return [license, String(version.prefix(7))].joined(separator: " · ")
    }
}

enum LicenseCatalog {
    /// The bundled list, in the collector's order: the app first, then the
    /// vendored notices, then the packages. Empty only for a build made
    /// without the Collect Licenses phase.
    static let entries: [LicenseEntry] = {
        guard let url = Bundle.main.url(forResource: "Licenses", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([LicenseEntry].self, from: data)
        else { return [] }
        return entries
    }()
}

/// Settings ▸ About ▸ Licenses: every component, one row each, the full text
/// a push away.
struct LicensesView: View {
    @State private var sectionInset = DS.Padding.l

    var body: some View {
        Form {
            Section {
                if LicenseCatalog.entries.isEmpty {
                    Text("No license information is available.")
                        .font(DS.Font.detail)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(LicenseCatalog.entries) { entry in
                        NavigationLink {
                            LicenseTextView(entry: entry)
                        } label: {
                            LicenseRow(entry: entry)
                        }
                        // Component names are catalog data, spoken verbatim.
                        .accessibilityLabel(Text(verbatim: entry.name))
                        .accessibilityValue(entry.licenseName)
                    }
                }
            } header: {
                // Match the actual side inset, including on wider layouts.
                GeometryReader { geometry in
                    let inset = geometry.frame(in: .named("licensesList")).minX
                    Color.clear
                        .onAppear { sectionInset = inset }
                        .onChange(of: inset) { sectionInset = $0 }
                }
                .frame(height: sectionInset)
                .listRowInsets(EdgeInsets())
            } footer: {
                Color.clear
                    .frame(height: sectionInset)
                    .listRowInsets(EdgeInsets())
            }
        }
        .coordinateSpace(name: "licensesList")
        .environment(\.defaultMinListHeaderHeight, 0)
        .navigationTitle("Licenses")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct LicenseRow: View {
    let entry: LicenseEntry

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Padding.xs) {
            Text(verbatim: entry.name)
            Text(verbatim: entry.licenseName)
                .foregroundColor(.secondary)
        }
    }
}

/// The license as its file reads: a heading with the name, version, and
/// homepage, the text beneath in monospace and selectable. Lines wrap at
/// the screen's edge rather than scrolling sideways — a license is quoted
/// whole, and a phone is narrower than the 80 columns most are wrapped at.
struct LicenseTextView: View {
    let entry: LicenseEntry

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Padding.l) {
                VStack(alignment: .leading, spacing: DS.Padding.xs) {
                    Text(verbatim: entry.name)
                        .font(DS.Font.title)
                    Text(verbatim: entry.summary)
                        .font(DS.Font.detail)
                        .foregroundColor(.secondary)
                    if let homepage = entry.homepage {
                        Link(destination: homepage) {
                            Text(verbatim: homepage.absoluteString)
                                .font(DS.Font.detail)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                Text(verbatim: entry.text)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DS.Padding.l)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(Text(verbatim: entry.name))
        .navigationBarTitleDisplayMode(.inline)
    }
}
