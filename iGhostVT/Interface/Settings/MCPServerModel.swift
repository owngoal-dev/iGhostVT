import SwiftUI
import UIKit

/// Settings' side of the MCP server: its switch, and — for as long as a
/// settings page showing it is up — the consent window, with each client
/// that asks put to the person as an alert.
///
/// The window is what keeps consent a person's: the daemon refuses every
/// request while it is closed, so nothing on the device can raise one
/// unless someone has this page open, and only the app may answer
/// (`MCPSupervisor`). It is renewed while the page stays up, lapses on its
/// own a few minutes after the app stops renewing it — long enough to
/// switch to the client and back — and is closed as the page goes, which
/// refuses whatever is still waiting.
@MainActor
final class MCPServerModel: ObservableObject {
    @Published private(set) var status = MCPServerStatus()

    private var loop: Task<Void, Never>?
    private weak var window: UIWindow?
    private var alert: AlertViewController?
    private var alertRequestID: UInt64?
    private var answered: Set<UInt64> = []

    func setWindow(_ window: UIWindow?) {
        self.window = window
    }

    func pageAppeared() {
        guard !AppEdition.isRemoteOnly, loop == nil else { return }
        loop = Task { [weak self] in
            var renewedAt = Date.distantPast
            var askedStatusAt = Date.distantPast
            while !Task.isCancelled {
                guard let model = self else { return }
                if Date().timeIntervalSince(askedStatusAt) >= 3 {
                    model.status = await MCPServerControl.status()
                    askedStatusAt = Date()
                }
                if model.status.isEnabled {
                    if Date().timeIntervalSince(renewedAt) >= 30, await MCPServerControl.setConsentWindow(open: true) {
                        renewedAt = Date()
                    }
                    model.show(await MCPServerControl.waitingRequests())
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func pageDisappeared() {
        loop?.cancel()
        loop = nil
        let alert = alert
        self.alert = nil
        alertRequestID = nil
        alert?.close()
        Task { await MCPServerControl.setConsentWindow(open: false) }
    }

    func setEnabled(_ enabled: Bool) {
        status.isEnabled = enabled
        Task {
            status = await MCPServerControl.setEnabled(enabled)
        }
    }

    /// The button goes at once; the restarted server reports none.
    func forgetClients() {
        status.authorizedClients = 0
        Task {
            status = await MCPServerControl.forgetClients()
        }
    }

    func copyEndpoint() {
        UIPasteboard.general.string = MCPConsent.endpoint
        CopiedIndicator.present(in: window)
    }

    /// One alert at a time, for the oldest request not answered yet; an
    /// alert whose request ran out or was settled meanwhile goes away.
    private func show(_ waiting: [MCPConsentRequest]) {
        if let id = alertRequestID {
            guard !waiting.contains(where: { $0.id == id }) else { return }
            let stale = alert
            alert = nil
            alertRequestID = nil
            stale?.close()
        }
        guard let request = waiting.first(where: { !answered.contains($0.id) }), let window else { return }
        let name = request.clientName.isEmpty ? String(localized: "An MCP client") : request.clientName
        let alert = AlertViewController(
            title: "“\(name)” Would Like to Use Your Terminals",
            message: "It could run commands and read what your terminals show. Allow it only if \(name) shows the code \(request.spacedCode).",
            actions: [
                AlertAction("Don’t Allow") { [weak self] in self?.answer(request.id, allow: false) },
                AlertAction("Allow", kind: .highlighted) { [weak self] in self?.answer(request.id, allow: true) },
            ],
        )
        self.alert = alert
        alertRequestID = request.id
        alert.present(in: window)
    }

    private func answer(_ id: UInt64, allow: Bool) {
        answered.insert(id)
        if alertRequestID == id {
            alert = nil
            alertRequestID = nil
        }
        Task { await MCPServerControl.answer(id, allow: allow) }
    }
}

/// Settings ▸ Advanced ▸ MCP on iPhone and iPad.
struct MCPServerSection: View {
    @ObservedObject var model: MCPServerModel

    var body: some View {
        Section {
            Toggle("MCP Server", isOn: Binding(get: { model.status.isEnabled }, set: { model.setEnabled($0) }))
                .disabled(model.status.isUnavailable)
            if model.status.isEnabled {
                Button { model.copyEndpoint() } label: {
                    HStack {
                        Text("Address")
                        Spacer(minLength: 12)
                        Text(verbatim: MCPConsent.endpoint)
                            .font(DS.Font.codeBody)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                }
                .foregroundColor(.primary)
                if model.status.authorizedClients > 0 {
                    Button("Forget Authorized Apps", role: .destructive) { model.forgetClients() }
                }
            }
        } header: {
            Text("MCP")
                .font(DS.Font.caption)
        } footer: {
            Text("Lets AI apps on this device use your terminals. Keep this page open while you connect a new app, so you can approve it.")
                .font(DS.Font.detail)
        }
    }
}
