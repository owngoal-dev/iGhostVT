//
//  MacMCPServerSheet.swift
//  iGhostVT
//

import SwiftUI

#if targetEnvironment(macCatalyst)

    /// The MCP server's sheet in the Mac's Advanced pane, laid out as the
    /// pane is: the addresses — this Mac's, then the local network's, each
    /// copied by a click — and how many apps are authorized, with Forget
    /// All — all of them at once, since nothing tells one client from
    /// another.
    struct MacMCPServerSheet: View {
        @ObservedObject var model: MCPServerModel
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            VStack(alignment: .leading, spacing: DS.Padding.l) {
                Text("MCP Server")
                    .font(DS.Font.labelEmphasis)
                MacSettingsRow("Address", labelWidth: Self.labelWidth) {
                    VStack(alignment: .leading, spacing: DS.Padding.xs) {
                        ForEach(model.addresses, id: \.self) { address in
                            MCPAddressText(address: address) { model.copy(address) }
                                .help("Click to Copy")
                        }
                    }
                }
                MacSettingsRow("Authorized Apps", labelWidth: Self.labelWidth) {
                    HStack(alignment: .firstTextBaseline, spacing: DS.Padding.m) {
                        Text(model.status.authorizedClients.formatted())
                        Button("Forget All") { model.forgetClients() }
                            .disabled(model.status.authorizedClients == 0)
                    }
                } details: {
                    MacSettingsNote("Forgotten apps must be approved again.")
                }
                Button("Done") { dismiss() }
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(DS.Padding.xl)
            // As wide as the address wants, within what a sheet on the
            // settings window can be.
            .frame(minWidth: 420, maxWidth: 560)
            .fittedSheet()
        }

        /// The pane's column is half the sheet; the address needs the room.
        private static let labelWidth: CGFloat = 110
    }

#endif
