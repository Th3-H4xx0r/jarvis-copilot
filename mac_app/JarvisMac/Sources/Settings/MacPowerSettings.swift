import AppKit
import SwiftUI

/// Settings → Mac power: keep-awake, Wake Mac's timer, the one-time helper setup,
/// the stored Mac password and the iPhone approval key (spec 2026-11-02).
struct MacPowerSettings: View {
    let model: AppModel
    @State private var password = ""
    @State private var passwordSet = MacPassword.isSet
    @State private var pinned = ApprovalKey.pinned
    @State private var message = ""
    @State private var busy = false

    private var helper: [String: Any] { J.obj(model.power["helper"]) }

    var body: some View {
        Form {
            Section("Keep awake") {
                Toggle("Keep Mac awake", isOn: Binding(get: { J.b(model.power["keep_awake"]) },
                                                       set: { model.setKeepAwake($0) }))
                Toggle("Check for Wake Mac requests while asleep (every 15 min)", isOn: Binding(
                    get: { model.power["timer_on"] == nil || J.b(model.power["timer_on"]) },
                    set: { on in JcLink.shared.request(["type": "mac_power_set", "timer_on": on]) { _ in model.refreshPower() } }))
                Text("Stays awake while an agent works or waits on you, and 10 minutes after. Closing the lid sleeps it, unless Keep Mac awake is on or you woke it from your iPhone (then 30 minutes). Lets go at 5% battery.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("One-time setup") {
                LabeledContent("Power helper", value: J.b(helper["running"]) ? "Running"
                               : J.b(helper["installed"]) ? "Installed, not running" : "Not installed")
                LabeledContent("sudo autofill", value: J.b(helper["askpass"]) ? "On" : "Off")
                HStack {
                    Button(J.b(helper["installed"]) ? "Reinstall" : "Install") { install() }.disabled(busy)
                    if busy { ProgressView().controlSize(.small) }
                }
                Text(passwordSet ? "Uses your saved Mac password, so there's no prompt."
                                 : "Asks for your admin password once.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Mac password") {
                if passwordSet {
                    LabeledContent("Saved", value: "In this Mac's Keychain only")
                    Button("Remove", role: .destructive) { MacPassword.remove(); passwordSet = false }
                }
                HStack {
                    SecureField(passwordSet ? "New Mac password" : "Mac password", text: $password)
                    Button("Save") { save() }.disabled(password.isEmpty)
                }
                Text("Jarvis types it only after you allow it, with Face ID on your iPhone or Touch ID here. It never leaves this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("iPhone approvals") {
                if let key = pinned { LabeledContent("Paired key", value: ApprovalKey.fingerprint(key)) }
                Button(pinned == nil ? "Pair iPhone" : "Pair again") { pair() }
                Text("Uses the iPhone's Face ID approval key (the one Car approvals use).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !message.isEmpty { Text(message).font(.caption) }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshPower() }
        .onChange(of: model.installResult.map { J.s($0["error"]) + J.s($0["ok"]) }) { _, _ in
            guard let r = model.installResult else { return }
            busy = false
            SecurityAgentWatch.shared.suppressed = false
            message = J.b(r["ok"]) ? "Installed." : "Setup failed: \(J.s(r["error"], "unknown error"))"
        }
    }

    private func install() {
        busy = true
        message = ""
        model.installResult = nil
        SecurityAgentWatch.shared.suppressed = true   // the setup's own admin dialog
        var req: [String: Any] = ["type": "power_install"]
        if let saved = MacPassword.read() { req["password"] = saved }
        JcLink.shared.request(req) { reply in
            if !J.b(reply["ok"]) {
                busy = false
                SecurityAgentWatch.shared.suppressed = false
                message = J.s(reply["error"], "jc-client isn't running")
            }
        }
    }

    private func save() {
        do {
            try MacPassword.store(password)
            passwordSet = true
            password = ""
            message = "Saved."
        } catch {
            message = error.localizedDescription
        }
    }

    private func pair() {
        JcLink.shared.request(["type": "approval_key"]) { reply in
            let key = J.s(reply["public_key"])
            guard J.b(reply["ok"]), !key.isEmpty else {
                message = J.s(reply["error"], "Couldn't get the iPhone's key")
                return
            }
            // The key comes through the server, so he checks it against the code his
            // iPhone works out from its own key before the Mac trusts it.
            let code = ApprovalKey.fingerprint(key)
            let alert = NSAlert()
            alert.messageText = "Does your iPhone show \(code)?"
            alert.informativeText = "On the iPhone: Agents → your Mac → ⋯ → Pairing code. Pair only if it's the same code."
            alert.addButton(withTitle: "Same code, pair")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else {
                message = "Not paired."
                return
            }
            do {
                try ApprovalKey.pin(key)
                pinned = key
                message = "Paired: \(code)."
            } catch {
                message = error.localizedDescription
            }
        }
    }
}
