import SwiftUI

/// Sign in with Toyota, on the Car page. The email and password go to the Jarvis server, which
/// hands them to Home Assistant's Toyota sign-in once; neither keeps the password.
struct ToyotaAccountCard: View {
    @ObservedObject var store: ToyotaStore
    var onSignIn: () -> Void
    @State private var confirmSignOut = false
    @State private var error: String?

    var body: some View {
        CardGroup("Toyota account",
                  footer: "Jarvis reaches your car through your Home Assistant's Toyota integration. Your password goes to Toyota once and isn't kept.") {
            content
            if let error {
                Row { Text(error).font(.footnote).foregroundStyle(JcTheme.danger) }
            }
        }
        .confirmationDialog("Sign out of Toyota?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) {
                error = nil
                Task {
                    do { try await store.signOut() } catch { self.error = apiErrorMessage(error) }
                }
            }
        } message: {
            Text("Jarvis and the Car page lose the remote, status and climate until you sign in again.")
        }
    }

    @ViewBuilder private var content: some View {
        switch store.account?.state {
        case nil:
            if let problem = store.problem {
                // The first load failed (not paired, server down): say so, and let him try again.
                Row {
                    HStack {
                        Text(problem).font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                        Button("Retry") { Task { await store.load() } }
                            .buttonStyle(.jcGlass(compact: true))
                    }
                }
            } else {
                Row { ProgressView().frame(maxWidth: .infinity) }
            }
        case .signedIn?:
            Row {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.account?.email ?? "Signed in").font(.body.weight(.semibold))
                        Text("Signed in").font(.caption).foregroundStyle(JcTheme.success)
                    }
                    Spacer()
                    Button("Sign Out", role: .destructive) { confirmSignOut = true }
                        .buttonStyle(.jcGlass(tint: JcTheme.danger, compact: true))
                }
            }
        case .signedOut?, .reauth?:
            Row {
                Button {
                    onSignIn()
                } label: {
                    Label(store.account?.state == .reauth ? "Sign in again" : "Sign in with Toyota",
                          systemImage: "person.badge.key.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.jcGlass(full: true))
            }
        case .some:
            Row {
                Text(store.account?.blockedReason ?? "Toyota isn't available.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

/// Email and password, then the code Toyota sends — Home Assistant's own sign-in steps.
struct ToyotaSignInSheet: View {
    @ObservedObject var store: ToyotaStore
    @Environment(\.dismiss) private var dismiss

    enum Step: Equatable {
        case password
        case code(flowID: String)
    }

    @State private var step: Step = .password
    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Text(step == .password
                         ? "Sign in with the email and password you use in the Toyota app."
                         : "Toyota sent a verification code to your email or phone.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                    CardGroup { fields }
                    if let error {
                        Text(error).font(.footnote).foregroundStyle(JcTheme.danger)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                    }
                    Button(action: submit) {
                        if working { ProgressView() } else {
                            Text(step == .password ? "Sign In" : "Verify").frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.jcGlass(full: true))
                    .disabled(working || !ready)
                    .padding(.horizontal, 16)
                    if case .code = step {
                        // An expired sign-in can only be restarted from the email and password.
                        Button("Start over") {
                            step = .password
                            code = ""
                            error = nil
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .disabled(working)
                    }
                }
                .padding(.vertical, 16)
            }
            .background(JcTheme.bg.ignoresSafeArea())
            .navigationTitle("Sign in with Toyota")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .presentationBackground(JcTheme.bg)
        .interactiveDismissDisabled(working)
    }

    @ViewBuilder private var fields: some View {
        switch step {
        case .password:
            Row {
                TextField("Email", text: $email)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Divider().padding(.leading, 16)
            Row {
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .onSubmit(submit)
            }
        case .code:
            Row {
                TextField("Verification code", text: $code)
                    .textContentType(.oneTimeCode)
                    .keyboardType(.numberPad)
                    .onSubmit(submit)
            }
        }
    }

    private var ready: Bool {
        switch step {
        case .password: return !email.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty
        case .code: return !code.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private func submit() {
        guard ready, !working else { return }
        working = true
        error = nil
        Task {
            do {
                let next: ToyotaAPI.SignInStep
                switch step {
                case .password: next = try await store.signIn(email: email, password: password)
                case .code(let flowID): next = try await store.submitCode(flowID: flowID, code: code)
                }
                switch next {
                case .code(let flowID):
                    password = ""   // not needed again; don't keep it around
                    step = .code(flowID: flowID)
                case .done:
                    dismiss()
                }
            } catch {
                self.error = apiErrorMessage(error)
            }
            working = false
        }
    }
}
