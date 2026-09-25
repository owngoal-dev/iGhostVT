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

    /// "MIT · 1.5.1" — the identifier, then the version when there is one.
    var summary: String {
        [license, version].compactMap(\.self).joined(separator: " · ")
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
    var body: some View {
        Form {
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
                    // Component names and license identifiers are catalog
                    // data, so the label is the row's own text, verbatim.
                    .accessibilityLabel(Text(verbatim: entry.name))
                    .accessibilityValue(entry.summary)
                }
            }
            SettingsFormSpacer()
        }
        .navigationTitle("Licenses")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct LicenseRow: View {
    let entry: LicenseEntry

    var body: some View {
        HStack {
            Text(verbatim: entry.name)
            Spacer()
            Text(verbatim: entry.summary)
                .font(DS.Font.detail)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
    }
}

/// The license as its file reads: a heading with the name, version, and
/// homepage, the text beneath in monospace and selectable. Lines wrap at
/// the screen's edge rather than scrolling sideways — a license is quoted
/// whole, and a phone is narrower than the 80 columns most are wrapped at.
private struct LicenseTextView: View {
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
