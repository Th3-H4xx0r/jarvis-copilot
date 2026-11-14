import SwiftUI

/// Where uploads go: Google Drive, SFTP, FTP or an SMB share, each handled by the server's rclone.
/// Passwords and tokens go straight into the server's rclone config and are never shown again.
struct DashcamDestinationsView: View {
    @State private var destinations: [DashcamDestination] = []
    @State private var error: String?
    @State private var adding = false
    @State private var testing: String?
    @State private var results: [String: String] = [:]
    @State private var confirmRemove: DashcamDestination?
    @State private var signingIn: String?

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
                                if d.type == "drive" {
                                    Button { Task { await signInAgain(d) } } label: { Label("Sign in again", systemImage: "person.badge.key") }
                                }
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
        .jcPageChrome("Destinations")
        .task { await load() }
        .refreshable { await load() }
        .alert("Remove \(confirmRemove?.name ?? "this destination")?",
               isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } })) {
            Button("Remove", role: .destructive) { if let d = confirmRemove { Task { await delete(d) } } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Clips already copied there stay there. New uploads stop going to it.")
        }
        .sheet(isPresented: $adding) {
            NavigationStack { DashcamAddDestinationView { Task { await load() } } }
        }
    }

    private func row(_ d: DashcamDestination) -> some View {
        HStack(spacing: 12) {
            JcIcon(Self.symbol(d.type), size: 20).foregroundStyle(JcTheme.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(d.name).font(.subheadline.weight(.semibold))
                Text("\(d.type.uppercased()) · \(d.path.isEmpty ? "/" : d.path)").font(.caption).foregroundStyle(JcTheme.muted)
                if let r = results[d.id] ?? (d.signInExpired ? Self.expiredNote : d.error) {
                    Text(r).font(.caption).foregroundStyle(r == "Works" ? JcTheme.success : JcTheme.amber)
                }
            }
            Spacer()
            if d.signInExpired {
                Button {
                    Task { await signInAgain(d) }
                } label: {
                    if signingIn == d.id { JcLoader() } else { Text("Sign in") }
                }
                .buttonStyle(.jcGlass(compact: true))
                .disabled(signingIn != nil)
            } else {
                Button {
                    Task { await test(d) }
                } label: {
                    if testing == d.id || signingIn == d.id { JcLoader() } else { Text("Test") }
                }
                .buttonStyle(.jcGlass(compact: true))
            }
            Button { confirmRemove = d } label: { JcIcon("trash", size: 15) }
                .buttonStyle(.jcGlass(tint: JcTheme.danger, compact: true))
                .accessibilityLabel("Remove \(d.name)")
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

    static let expiredNote = "Google sign-in expired — clips wait on the phone until you sign in again"

    /// Renews the same destination (clips already copied keep pointing at it): the one sign-in the dashcam
    /// screens share (`DashcamDriveSignIn`).
    private func signInAgain(_ d: DashcamDestination) async {
        signingIn = d.id
        defer { signingIn = nil }
        results[d.id] = nil
        let failure = await DashcamDriveSignIn.shared.signIn(d.id)
        results[d.id] = failure ?? "Works"
        if failure == nil { await load() }
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
    @State private var signingIn = false
    @State private var google = DashcamGoogleSignIn()
    @State private var kinds: Set<DashcamClipKind> = Set(DashcamClipKind.allCases)
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                JcSegmented(items: Kind.allCases, selection: $kind, label: \.label)
                    .padding(.horizontal, 20)
                CardGroup {
                    field("Name", text: $name, placeholder: kind.label)
                    RowDivider()
                    field("Folder", text: $path, placeholder: "Dashcam")
                }
                if kind == .drive {
                    CardGroup("Google sign-in", footer: "Enter your own Google Cloud OAuth client (type Desktop app — rclone's shared one runs out of quota) and tap Sign in with Google: the token fills in by itself. Or paste the JSON `rclone authorize drive <id> <secret>` prints.") {
                        field("Client id", text: $clientID, placeholder: "….apps.googleusercontent.com")
                        RowDivider()
                        Row { SecureField("Client secret", text: $clientSecret) }
                        RowDivider()
                        Row {
                            Button {
                                Task { await signInWithGoogle() }
                            } label: {
                                HStack { if signingIn { JcLoader() }; Text(token.isEmpty ? "Sign in with Google" : "Signed in — sign in again") }
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.jcGlass(compact: true))
                            .disabled(signingIn || clientID.trimmingCharacters(in: .whitespaces).isEmpty
                                      || clientSecret.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        RowDivider()
                        Row { TextField("Token JSON", text: $token, axis: .vertical).lineLimit(2...5).font(.caption.monospaced()) }
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
                    HStack { if busy { JcLoader().foregroundStyle(.white) }; Text("Add") }.frame(maxWidth: .infinity)
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
                Text(title).foregroundStyle(JcTheme.muted)
                TextField(placeholder, text: text).multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
        }
    }

    private func signInWithGoogle() async {
        signingIn = true
        defer { signingIn = false }
        do {
            token = try await google.signIn(clientID: clientID.trimmingCharacters(in: .whitespaces),
                                            clientSecret: clientSecret.trimmingCharacters(in: .whitespaces))
            error = nil
        } catch {
            self.error = error.localizedDescription
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
            DashcamSync.shared.destinationsChanged()       // clips refused for "no destination" go now
            onAdded()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// "Google Drive is signed out" on a dashcam screen: the system's centred alert with Sign in (the Destinations
/// screen's sign-in for that destination) and Not now. Once a visit — Not now holds until he leaves the screen,
/// however often playback or uploads ask Drive again. `active`: this screen is the one on top (the page under a
/// clip's page must not present it too). `signedIn` runs after a sign-in that worked (the player retries its clip).
struct DashcamDriveSignInAlert: ViewModifier {
    var active: Bool
    var signedIn: () -> Void = {}
    @ObservedObject private var state = DashcamDriveSignIn.shared
    @State private var dismissed: String?
    /// Why the sign-in from this popup didn't take, shown in a second alert with Try again.
    @State private var failure: String?

    func body(content: Content) -> some View {
        content
            .alert("Google Drive is signed out", isPresented: Binding(
                get: { active && failure == nil && state.needed != nil && dismissed != state.needed?.destinationID },
                set: { if !$0, let id = state.needed?.destinationID { dismissed = id } })) {
                Button("Sign in") { signIn() }
                Button("Not now", role: .cancel) {}
            } message: {
                Text(DashcamDriveSignIn.message(state.needed))
            }
            .alert("Couldn't sign in to Google Drive", isPresented: Binding(
                get: { active && failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("Try again") { signIn() }
                Button("Not now", role: .cancel) {}
            } message: {
                Text(failure ?? "")
            }
            // Signed in (here or anywhere): a later sign-out may ask again.
            .onChange(of: state.needed?.destinationID) { _, id in if id == nil { dismissed = nil; failure = nil } }
    }

    private func signIn() {
        guard let id = state.needed?.destinationID else { return }
        failure = nil
        Task {
            // Cancelling Google's sheet is his choice, not a failure to report.
            if let why = await state.signIn(id) {
                if why != DashcamGoogleSignIn.Failure.cancelled.errorDescription { failure = why }
            } else {
                signedIn()
            }
        }
    }
}

/// The player's line when a clip can't play because Drive is signed out — instead of a crossed-out play icon:
/// what's wrong, and Sign in.
struct DashcamDriveSignInLine: View {
    var signedIn: () -> Void
    @ObservedObject private var state = DashcamDriveSignIn.shared

    var body: some View {
        if let needed = state.needed {
            CardGroup {
                Row {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Google Drive is signed out", systemImage: "person.crop.circle.badge.exclamationmark")
                            .font(.subheadline.weight(.semibold))
                        Text(state.problem ?? "Sign in again to play this clip from your Drive. Your clips are still there.")
                            .font(.caption).foregroundStyle(JcTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        Button {
                            Task { if await state.signIn(needed.destinationID) == nil { signedIn() } }
                        } label: {
                            if state.signingIn { JcLoader() } else { Text("Sign in") }
                        }
                        .buttonStyle(.jcGlass(compact: true, full: true))
                        .disabled(state.signingIn)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
}
