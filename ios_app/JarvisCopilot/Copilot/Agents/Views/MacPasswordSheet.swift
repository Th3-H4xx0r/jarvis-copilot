import SwiftUI

/// A Mac password prompt, built like the app's other confirm sheets
/// (IntegrationDeleteSheet): black like the screens behind it, a left title, the
/// request in one inset group, exactly as tall as its content, and the app's own
/// buttons — Don't Allow beside Allow (Face ID). The request text is shown in
/// full: his Face ID signature covers exactly that text. Allow and Don't Allow go
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
    @State private var height: CGFloat = 0
    @State private var taps = 0
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let over = request.expires <= context.date
            VStack(alignment: .leading, spacing: 0) {
                Text(MacPasswordSheetCopy.title(kind: request.kind))
                    .font(JcText.title)
                    .foregroundStyle(JcTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                meta(now: context.date)
                    .padding(.top, 4)

                if MacPasswordSheetCopy.showsRequest(kind: request.kind, context: request.context) {
                    InsetGroup { requestText }
                        .padding(.top, 16)
                }

                if let error {
                    Text(error)
                        .font(JcText.small)
                        .foregroundStyle(JcTheme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 12)
                        .transition(.opacity)
                }

                HStack(spacing: 10) {
                    GlassButton(title: "Don’t Allow", ghost: true,
                                action: over || answering != nil ? nil : { reply(allow: false) })
                    GradientButton("Allow", symbol: "faceid", busy: answering == true, full: true,
                                   action: over || answering != nil ? nil : { reply(allow: true) })
                        .accessibilityHint("Confirms with Face ID, then your Mac types its password")
                }
                .padding(.top, 20)
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Exactly as tall as what's in it: a fixed detent leaves a dead band.
        .background(GeometryReader { g in
            Color.clear.preference(key: MacPasswordSheetHeight.self, value: g.size.height)
        })
        .onPreferenceChange(MacPasswordSheetHeight.self) { height = $0 }
        .background(JcTheme.bg)
        .animation(.snappy(duration: 0.2), value: error)
        .sensoryFeedback(.impact(weight: .light), trigger: taps)
        .sensoryFeedback(trigger: error) { _, new in new == nil ? nil : .error }
        .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.height(max(height, 200))])
        .presentationDragIndicator(.visible)
        .presentationBackground(JcTheme.bg)
        .interactiveDismissDisabled(answering != nil)
        .task(id: request.id) {
            let left = request.expires.timeIntervalSinceNow
            if left > 0 { try? await Task.sleep(for: .seconds(left)) }
            if !Task.isCancelled { expired() }
        }
    }

    /// "Pranav's MacBook Pro · 1:42 left" (amber under 30 s).
    private func meta(now: Date) -> some View {
        let left = request.expires.timeIntervalSince(now)
        return HStack(spacing: 6) {
            Text(macName).lineLimit(1)
            Text("·").accessibilityHidden(true)
            Text(MacPasswordApproval.countdown(request.expires, now: now))
                .monospacedDigit()
                .foregroundStyle(left > 0 && left <= 30 ? JcTheme.amber : JcTheme.muted)
        }
        .font(JcText.body)
        .foregroundStyle(JcTheme.muted)
        .accessibilityElement(children: .combine)
    }

    /// The whole request: mono for a sudo command, plain text otherwise. Hugs a
    /// short one, scrolls a long one (never cut short).
    private var requestText: some View {
        let text = Text(request.context)
            .font(request.kind == "sudo" ? .system(size: 14, design: .monospaced) : JcText.body)
            .foregroundStyle(JcTheme.text)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        return ViewThatFits(in: .vertical) {
            text
            ScrollView { text }.frame(maxHeight: 240).scrollIndicators(.visible)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Request: \(request.context)")
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

private struct MacPasswordSheetHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
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

    /// The compact Needs-you row's glyph, by what asked.
    static func symbol(kind: String) -> String {
        switch kind {
        case "keychain": return "key.fill"
        case "sudo": return "apple.terminal.fill"
        default: return "lock.laptopcomputer"
        }
    }

    /// The request box, unless it would only repeat the title ("Unlock Mac").
    static func showsRequest(kind: String, context: String) -> Bool {
        let text = context.trimmingCharacters(in: .whitespacesAndNewlines)
        return !text.isEmpty && !(kind == "unlock" && text == "Unlock Mac")
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
