import SwiftUI

/// Where uploads go: Google Drive, SFTP, FTP or an SMB share, each handled by the server's rclone.
/// Passwords and tokens go straight into the server's rclone config and are never shown again.
struct DashcamDestinationsView: View {
    @State private var destinations: [DashcamDestination] = []
    @State private var error: String?
    @State private var adding = false
    @State private var testing: String?
    @State private var results: [String: String] = [:]

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if let error {
                    Text(error).font(.footnote).foregroundStyle(JcTheme.amber).padding(.horizontal, 20)
                }
                CardGroup("Destinations", footer: "Every finished upload is copied to each destination by the Jarvis server. A clip leaves the phone once all of them have it.") {
                    if destinations.isEmpty {
                        CardEmptyBlock("No destinations yet — clips stay on the server and the phone.", symbol: "externaldrive")
                    }
                    ForEach(Array(destinations.enumerated()), id: \.element.id) { i, d in
                        if i > 0 { RowDivider() }
                        Row(minHeight: 60) { row(d) }
                            .contextMenu {
                                Button(role: .destructive) { Task { await delete(d) } } label: { Label("Remove", systemImage: "trash") }
                            }
                    }
                }
                Button { adding = true } label: { Label("Add destination", systemImage: "plus").frame(maxWidth: .infinity) }
                    .buttonStyle(.jcGlass)
                    .padding(.horizontal, 20)
            }
            .padding(.vertical, 12)
        }
        .background(JcTheme.bg.ignoresSafeArea())
        .navigationTitle("Destinations")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $adding) {
            NavigationStack { DashcamAddDestinationView { Task { await load() } } }
        }
    }

    private func row(_ d: DashcamDestination) -> some View {
        HStack(spacing: 12) {
            JcIcon(Self.symbol(d.type), size: 20).foregroundStyle(JcTheme.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(d.name).font(.subheadline.weight(.semibold))
                Text("\(d.type.uppercased()) · \(d.path.isEmpty ? "/" : d.path)").font(.caption).foregroundStyle(.secondary)
                if let r = results[d.id] ?? d.error {
                    Text(r).font(.caption).foregroundStyle(r == "Works" ? JcTheme.success : JcTheme.amber)
                }
            }
            Spacer()
            Button {
                Task { await test(d) }
            } label: {
                if testing == d.id { ProgressView() } else { Text("Test") }
            }
            .buttonStyle(.jcGlass(compact: true))
        }
    }

    static func symbol(_ type: String) -> String {
        switch type {
        case "drive": return "externaldrive.badge.icloud"
        case "smb": return "server.rack"
        default: return "network"
        }
    }

    private func load() async {
        do { destinations = try await DashcamAPI().destinations(); error = nil }
        catch { self.error = error.localizedDescription }
    }

    private func test(_ d: DashcamDestination) async {
        testing = d.id
        defer { testing = nil }
        do { results[d.id] = try await DashcamAPI().testDestination(d.id) ?? "Works" }
        catch { results[d.id] = error.localizedDescription }
    }

    private func delete(_ d: DashcamDestination) async {
        do { try await DashcamAPI().deleteDestination(d.id); await load() }
        catch { self.error = error.localizedDescription }
    }
}

struct DashcamAddDestinationView: View {
    enum Kind: String, CaseIterable, Identifiable {
        case drive, sftp, ftp, smb
        var id: String { rawValue }
        var label: String {
            switch self {
            case .drive: return "Google Drive"
            case .sftp: return "SFTP"
            case .ftp: return "FTP"
            case .smb: return "SMB share"
            }
        }
    }

    var onAdded: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var kind: Kind = .drive
    @State private var name = ""
    @State private var path = "Dashcam"
    @State private var host = ""
    @State private var port = ""
    @State private var user = ""
    @State private var password = ""
    @State private var token = ""
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var kinds: Set<DashcamClipKind> = Set(DashcamClipKind.allCases)
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Picker("Type", selection: $kind) { ForEach(Kind.allCases) { Text($0.label).tag($0) } }
                    .pickerStyle(.segmented).padding(.horizontal, 20)
                CardGroup {
                    field("Name", text: $name, placeholder: kind.label)
                    RowDivider()
                    field("Folder", text: $path, placeholder: "Dashcam")
                }
                if kind == .drive {
                    CardGroup("Google sign-in", footer: "On the Mac, run skills/smart-home/jarvis-dashcam/scripts/connect_drive.sh — it signs in to Google in your browser and adds the destination itself. Or paste the token it prints here. A Google Cloud client id/secret of your own is optional (rclone's shared one is being retired).") {
                        Row { TextField("Token JSON", text: $token, axis: .vertical).lineLimit(2...5).font(.caption.monospaced()) }
                        RowDivider()
                        field("Client id", text: $clientID, placeholder: "optional")
                        RowDivider()
                        Row { SecureField("Client secret (optional)", text: $clientSecret) }
                    }
                } else {
                    CardGroup("Server") {
                        field("Host", text: $host, placeholder: "nas.local")
                        RowDivider()
                        field("Port", text: $port, placeholder: kind == .sftp ? "22" : kind == .ftp ? "21" : "445")
                        RowDivider()
                        field("User", text: $user, placeholder: "")
                        RowDivider()
                        Row { SecureField("Password", text: $password) }
                    }
                }
                CardGroup("Send") {
                    ForEach(Array(DashcamClipKind.allCases.enumerated()), id: \.element) { i, k in
                        if i > 0 { RowDivider() }
                        Row {
                            Toggle(k.label + (k == .normal ? " footage" : "s"), isOn: Binding(
                                get: { kinds.contains(k) },
                                set: { if $0 { kinds.insert(k) } else { kinds.remove(k) } }))
                            .tint(JcTheme.accent)
                        }
                    }
                }
                if let error {
                    Text(error).font(.footnote).foregroundStyle(JcTheme.amber).padding(.horizontal, 20)
                }
                Button {
                    Task { await add() }
                } label: {
                    HStack { if busy { ProgressView().tint(.white) }; Text("Add") }.frame(maxWidth: .infinity)
                }
                .buttonStyle(.jcGlass)
                .disabled(busy || !valid)
                .padding(.horizontal, 20)
            }
            .padding(.vertical, 12)
        }
        .background(JcTheme.bg.ignoresSafeArea())
        .navigationTitle("Add destination")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
    }

    private var valid: Bool {
        kind == .drive ? !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            : !host.isEmpty && !user.isEmpty && !kinds.isEmpty
    }

    private func field(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        Row {
            HStack {
                Text(title).foregroundStyle(.secondary)
                TextField(placeholder, text: text).multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
        }
    }

    private func add() async {
        busy = true
        defer { busy = false }
        var body: [String: Any] = ["type": kind.rawValue, "name": name.isEmpty ? kind.label : name, "path": path,
                                   "kinds": DashcamClipKind.allCases.filter { kinds.contains($0) }.map(\.rawValue)]
        if kind == .drive {
            body["token"] = token.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clientID.isEmpty { body["client_id"] = clientID }
            if !clientSecret.isEmpty { body["client_secret"] = clientSecret }
        } else {
            body["host"] = host
            body["user"] = user
            if let p = Int(port) { body["port"] = p }
            if !password.isEmpty { body["password"] = password }
        }
        do {
            _ = try await DashcamAPI().addDestination(body)
            onAdded()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
