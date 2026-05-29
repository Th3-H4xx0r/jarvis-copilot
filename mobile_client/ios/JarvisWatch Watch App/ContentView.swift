import SwiftUI

/// The single watch screen. Renders per `WatchViewModel.state`, plus a
/// not-configured banner driven by the phone's login-state.
struct ContentView: View {
    @ObservedObject var connector: WatchConnector
    @StateObject private var vm: WatchViewModel
    @State private var showingDictation = false
    @State private var dictated = ""

    init(connector: WatchConnector) {
        self.connector = connector
        // Audio is played by WatchConnector when the clip arrives via transferFile.
        _vm = StateObject(wrappedValue: WatchViewModel(
            asker: { await connector.ask(text: $0) }))
    }

    var body: some View {
        VStack(spacing: 8) {
            if !connector.loggedIn {
                setupBanner
            } else {
                content
            }
        }
        .padding()
        .sheet(isPresented: $showingDictation) { dictationSheet }
    }

    @ViewBuilder private var content: some View {
        switch vm.state {
        case .idle, .listening:
            micButton
            Text("Tap to talk").font(.footnote).foregroundStyle(.secondary)
        case .thinking:
            ProgressView()
            Text("Thinking…").font(.footnote)
        case .answer(let text):
            ScrollView {
                Text(text).font(.body).frame(maxWidth: .infinity, alignment: .leading)
            }
            micButton
        case .error(let message):
            Text("⚠︎").font(.title3)
            Text(message).font(.footnote).multilineTextAlignment(.center)
            Button("Try again") { showingDictation = true }
        }
    }

    private var micButton: some View {
        Button { showingDictation = true } label: {
            Image(systemName: "mic.fill").font(.system(size: 30))
        }
        .buttonStyle(.borderedProminent)
    }

    private var setupBanner: some View {
        VStack(spacing: 6) {
            Text("⚠︎").font(.title2)
            Text("Open JarvisCopilot on your iPhone to set this up.")
                .font(.footnote).multilineTextAlignment(.center)
        }
    }

    // A focused TextField brings up the watchOS input surface, which offers
    // Dictation. (Alternative: WKInterfaceController.presentTextInputController.)
    private var dictationSheet: some View {
        VStack(spacing: 10) {
            TextField("Speak…", text: $dictated)
                .onSubmit { submit() }
            Button("Ask") { submit() }
                .buttonStyle(.borderedProminent)
                .disabled(dictated.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding()
    }

    private func submit() {
        let text = dictated
        dictated = ""
        showingDictation = false
        Task { await vm.submit(text: text) }
    }
}
