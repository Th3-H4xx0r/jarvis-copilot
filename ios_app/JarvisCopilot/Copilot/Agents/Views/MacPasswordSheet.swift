import SwiftUI

/// A Mac password prompt as an authorization sheet, modelled on Apple's own:
/// the symbol, what asked and which Mac, ALL of the request text (his Face ID
/// signature covers exactly that text, so it is never cut short), the time
/// left, then Allow with Face ID and Don't Allow. Allow and Don't Allow go
/// through `AgentsStore.answerMacPassword` untouched; the page closes the sheet
/// once the request leaves the list (answered) or runs out.
struct MacPasswordSheet: View {
    let request: MacPasswordRequest
    let macName: String
    /// `store.answerMacPassword(request, allow:)`: nil when it went (or Face ID
    /// was cancelled, nothing sent), else why not.
    let answer: (Bool) async -> String?
    /// The request ran out with the sheet open.
    var expired: () -> Void = {}

    @State private var answering: Bool?
    @State private var error: String?
    @State private var detent: PresentationDetent = .medium
    @State private var taps = 0
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let over = request.expires <= context.date
            VStack(spacing: 0) {
                hero(now: context.date)
                if !request.context.isEmpty {
                    pane.padding(.top, 18)
                }
                Spacer(minLength: 14)
                Text("Face ID signs exactly this request. Your Mac checks the signature before it types anything.")
                    .font(.caption)
                    .foregroundStyle(JcTheme.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
                if let error {
                    Label { Text(error) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                        .font(.footnote)
                        .foregroundStyle(JcTheme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 10)
                        .transition(.opacity)
                }
                buttons(disabled: over || answering != nil)
                    .padding(.top, 14)
            }
            .padding(.horizontal, 24)
            .padding(.top, 26)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .animation(.snappy(duration: 0.25), value: error)
        .sensoryFeedback(.impact(weight: .light), trigger: taps)
        .sensoryFeedback(trigger: error) { _, new in new == nil ? nil : .error }
        .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(34)
        .presentationBackground(JcTheme.surface)
        .interactiveDismissDisabled(answering != nil)
        .onAppear { if typeSize.isAccessibilitySize { detent = .large } }
        .task(id: request.id) {
            let left = request.expires.timeIntervalSinceNow
            if left > 0 { try? await Task.sleep(for: .seconds(left)) }
            if !Task.isCancelled { expired() }
        }
    }

    // MARK: pieces

    private func hero(now: Date) -> some View {
        let left = request.expires.timeIntervalSince(now)
        return VStack(spacing: 10) {
            Image(systemName: MacPasswordSheetCopy.symbol(kind: request.kind))
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(JcTheme.accent)
                .frame(width: 60, height: 60)
                .background(JcTheme.accent.opacity(0.14), in: Circle())
                .accessibilityHidden(true)
            Text(MacPasswordSheetCopy.title(kind: request.kind))
                .font(.title3.weight(.bold))
                .foregroundStyle(JcTheme.text)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 6) {
                Text(macName).lineLimit(1)
                Text("·").accessibilityHidden(true)
                Text(MacPasswordApproval.countdown(request.expires, now: now))
                    .monospacedDigit()
                    .foregroundStyle(left > 0 && left <= 30 ? JcTheme.amber : JcTheme.muted)
            }
            .font(.subheadline)
            .foregroundStyle(JcTheme.muted)
            .accessibilityElement(children: .combine)
        }
        .frame(maxWidth: .infinity)
    }

    /// The whole request text: hugs a short one, scrolls a long one.
    private var pane: some View {
        let text = Text(request.context)
            .font(.system(.footnote, design: .monospaced))
            .foregroundStyle(AgentPane.paneText)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        return ViewThatFits(in: .vertical) {
            text
            ScrollView { text }.scrollIndicators(.visible)
        }
        .background(AgentPane.pane, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(JcTheme.border, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Request: \(request.context)")
    }

    private func buttons(disabled: Bool) -> some View {
        VStack(spacing: 4) {
            Button { reply(allow: true) } label: {
                HStack(spacing: 8) {
                    if answering == true {
                        ProgressView().controlSize(.small).tint(.white)
                    } else {
                        Image(systemName: "faceid").font(.body.weight(.semibold))
                    }
                    Text("Allow with Face ID")
                }
            }
            .buttonStyle(MacActionButtonStyle(prominent: true, height: 50))
            .accessibilityHint("Confirms with Face ID, then your Mac types its password")

            Button { reply(allow: false) } label: {
                HStack(spacing: 8) {
                    if answering == false { ProgressView().controlSize(.small).tint(JcTheme.accent) }
                    Text("Don’t Allow")
                }
                .font(.body.weight(.medium))
                .foregroundStyle(JcTheme.accent)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Your Mac won’t type the password")
        }
        .disabled(disabled)
        .opacity(disabled && answering == nil ? 0.45 : 1)
    }

    private func reply(allow: Bool) {
        answering = allow
        error = nil
        taps += 1
        Task {
            error = await answer(allow)
            answering = nil
        }
    }
}

/// The sheet's words, kept pure for the tests.
enum MacPasswordSheetCopy {
    /// The bold title, by what asked.
    static func title(kind: String) -> String {
        switch kind {
        case "sudo": return "sudo wants your Mac password"
        case "admin": return "Admin access on your Mac"
        case "keychain": return "Keychain access"
        case "unlock": return "Unlock your Mac"
        default: return "Your Mac wants its password"
        }
    }

    static func symbol(kind: String) -> String {
        switch kind {
        case "keychain": return "key.fill"
        case "sudo": return "apple.terminal.fill"
        default: return "lock.laptopcomputer"
        }
    }
}

/// Which password request the sheet shows, one at a time.
enum MacPasswordQueue {
    /// The next one to put up: the first live request he hasn't swiped away.
    static func next(_ requests: [MacPasswordRequest], snoozed: Set<String>,
                     now: Date = Date()) -> MacPasswordRequest? {
        requests.first { !snoozed.contains($0.id) && $0.expires > now }
    }

    /// The open sheet's request was answered (it left the list) or ran out.
    static func isDone(_ request: MacPasswordRequest, in requests: [MacPasswordRequest],
                       now: Date = Date()) -> Bool {
        request.expires <= now || !requests.contains { $0.id == request.id }
    }
}
