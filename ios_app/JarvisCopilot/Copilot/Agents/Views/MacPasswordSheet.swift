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
                Text(MacPasswordSheetCopy.title(for: request))
                    .font(JcText.title)
                    .foregroundStyle(JcTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if let from = MacPasswordSheetCopy.subtitle(for: request) {
                    Text("Asked \(from)")
                        .font(JcText.body)
                        .foregroundStyle(JcTheme.muted)
                        .padding(.top, 4)
                }
                meta(now: context.date)
                    .padding(.top, 4)

                if MacPasswordSheetCopy.showsRequest(kind: request.kind, context: request.context) {
                    InsetGroup { requestText }
                        .padding(.top, 16)
                }
                if let warning = MacPasswordSheetCopy.warning(kind: request.kind) {
                    Text(warning)
                        .font(JcText.small)
                        .foregroundStyle(JcTheme.amber)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 10)
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
                        .accessibilityHint(MacPasswordSheetCopy.allowHint(for: request))
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

    /// The whole request: mono for a command (sudo, the IT agent's), plain text otherwise. Hugs a
    /// short one, scrolls a long one (never cut short): his Face ID signs exactly this text.
    private var requestText: some View {
        let text = Text(request.context)
            .font(MacPasswordSheetCopy.monospaced(kind: request.kind) ? .system(size: 14, design: .monospaced) : JcText.body)
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
    /// The bold title for a request: the PC's unlock (its jc-client asks "Unlock PC") says PC.
    static func title(for request: MacPasswordRequest) -> String {
        if request.kind == "rdp" { return "Remote Desktop to \(rdp(request.context).device ?? "your PC")" }
        return request.kind == "unlock" && request.context.hasPrefix("Unlock PC") ? "Unlock your PC" : title(kind: request.kind)
    }

    /// A Remote Desktop request's signed context: {"session","client":"ios"|"web","enc_pub","device"}.
    static func rdp(_ context: String) -> (device: String?, client: String?) {
        let obj = (try? JSONSerialization.jsonObject(with: Data(context.utf8))) as? [String: Any] ?? [:]
        let device = (obj["device"] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        return (device, obj["client"] as? String)
    }

    /// Where a request was asked from, for an rdp request ("from this iPhone" / "from the web");
    /// nil for the others.
    static func subtitle(for request: MacPasswordRequest) -> String? {
        if itKinds.contains(request.kind) {
            return request.why.isEmpty ? nil : "by the IT agent: \(request.why)"
        }
        guard request.kind == "rdp" else { return nil }
        switch rdp(request.context).client {
        case "web": return "from the web"
        case "ios": return "from this iPhone"
        default: return nil
        }
    }

    /// The bold title, by what asked.
    static func title(kind: String) -> String {
        switch kind {
        case "sudo": return "sudo wants your Mac password"
        case "admin": return "Admin access on your Mac"
        case "keychain": return "Keychain access"
        case "unlock": return "Unlock your Mac"
        case "rdp": return "Remote Desktop to your PC"
        case "admin-run": return "Run as admin on your PC"
        case "pc-run": return "Approve a command on your PC"
        default: return "Your Mac wants its password"
        }
    }

    /// The compact Needs-you row's glyph, by what asked.
    static func symbol(kind: String) -> String {
        switch kind {
        case "keychain": return "key.fill"
        case "sudo", "admin-run", "pc-run": return "apple.terminal.fill"
        case "rdp": return "display"
        default: return "lock.laptopcomputer"
        }
    }

    /// The request box, unless it would only repeat the title ("Unlock Mac" / "Unlock PC").
    static func showsRequest(kind: String, context: String) -> Bool {
        let text = context.trimmingCharacters(in: .whitespacesAndNewlines)
        // An rdp context is the signed JSON: the title and subtitle say it in words.
        return !text.isEmpty && kind != "rdp" && !(kind == "unlock" && (text == "Unlock Mac" || text == "Unlock PC"))
    }

    /// The PC asks for its unlock (its jc-client says "Unlock PC"), Remote Desktop and the IT agent's commands.
    static func isPC(_ request: MacPasswordRequest) -> Bool {
        request.kind == "rdp" || itKinds.contains(request.kind)
            || (request.kind == "unlock" && request.context.hasPrefix("Unlock PC"))
    }

    /// The IT agent's commands: admin-run runs elevated, pc-run (a destructive one) as him.
    static let itKinds: Set<String> = ["admin-run", "pc-run"]

    /// A command is shown in mono, exactly as it will run.
    static func monospaced(kind: String) -> Bool { kind == "sudo" || itKinds.contains(kind) }

    /// What the Face ID prompt says.
    static func faceIDReason(for request: MacPasswordRequest) -> String {
        switch request.kind {
        case "admin-run": return "Run as admin on your PC"
        case "pc-run": return "Run this command on your PC"
        case "rdp": return title(for: request)
        default: return "Type your \(isPC(request) ? "PC" : "Mac") password"
        }
    }

    /// VoiceOver's hint on Allow.
    static func allowHint(for request: MacPasswordRequest) -> String {
        switch request.kind {
        case "admin-run": return "Confirms with Face ID, then your PC runs this command once as admin"
        case "pc-run": return "Confirms with Face ID, then your PC runs this command once"
        default: return "Confirms with Face ID, then your \(isPC(request) ? "PC" : "Mac") types its password"
        }
    }

    /// The line under an IT command: it runs once, and only if he asked for it.
    static func warning(kind: String) -> String? {
        switch kind {
        case "admin-run": return "Runs once as admin on your PC. Approve only if you asked for this."
        case "pc-run": return "Runs once on your PC. Approve only if you asked for this."
        default: return nil
        }
    }
}

/// Which password request the sheet shows, one at a time.
enum MacPasswordQueue {
    /// The next one to put up: the first live request he hasn't swiped away.
    static func next(_ requests: [MacPasswordRequest], snoozed: Set<String>,
                     now: Date = Date()) -> MacPasswordRequest? {
        // A Remote Desktop request the session screen shows itself never gets a second card.
        requests.first { !snoozed.contains($0.id) && $0.expires > now && !RdpApproval.isInline($0) }
    }

    /// The open sheet's request was answered (it left the list) or ran out.
    static func isDone(_ request: MacPasswordRequest, in requests: [MacPasswordRequest],
                       now: Date = Date()) -> Bool {
        request.expires <= now || !requests.contains { $0.id == request.id }
    }
}
