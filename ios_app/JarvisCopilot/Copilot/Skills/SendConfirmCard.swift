import SwiftUI
import UIKit

/// "Text Shabd Patel?" over the app: who (photo or initials, full name, the number), what (the
/// message), and the answer — Send (Call) or ✕. Styled like the car approval card: black, the
/// app's glass card and glass buttons, no gradients.
struct SendConfirmCard: View {
    @ObservedObject var center: SendConfirmations

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.6).ignoresSafeArea()
            if let card = center.card {
                SendConfirmSheet(center: center, card: card)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.4, bounce: 0.15), value: center.card?.id)
    }
}

private struct SendConfirmSheet: View {
    @ObservedObject var center: SendConfirmations
    let card: SendConfirmations.Card

    var body: some View {
        VStack(spacing: 0) {
            ContactAvatar(card: card, size: 76)
                .padding(.top, 22)

            VStack(spacing: 4) {
                Text(card.title)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Text(card.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.top, 12)

            if !card.message.isEmpty {
                Text(card.message)
                    .font(.body)
                    .lineLimit(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(JcTheme.glassFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(JcTheme.glassBorder, lineWidth: 1))
                    .padding(.top, 16)
            }

            Group {
                if let outcome = center.outcome {
                    outcomeView(outcome)
                } else {
                    actions
                }
            }
            .padding(.top, 20)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity)
        .background(JcTheme.bg, in: RoundedRectangle(cornerRadius: JcTheme.cardRadius, style: .continuous))
        .background(JcTheme.glassFill, in: RoundedRectangle(cornerRadius: JcTheme.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: JcTheme.cardRadius, style: .continuous)
            .strokeBorder(JcTheme.glassBorder, lineWidth: 1))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .animation(.easeInOut(duration: 0.25), value: center.outcome)
        .accessibilityElement(children: .contain)
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button {
                Task { await center.tap(yes: false) }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.jcGlass(tint: .secondary, full: false))
            .accessibilityLabel("Don't \(card.actionTitle.lowercased())")

            Button {
                Task { await center.tap(yes: true) }
            } label: {
                HStack(spacing: 10) {
                    if center.answering {
                        ProgressView().tint(JcTheme.accent)
                    } else {
                        Image(systemName: card.actionSymbol)
                        Text(card.actionTitle)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 28)
            }
            .buttonStyle(.jcGlass(tint: JcTheme.accent, full: true))
        }
        .disabled(center.answering)
    }

    private func outcomeView(_ outcome: SendConfirmations.Outcome) -> some View {
        let ok = outcome == .sent
        let text = ok ? (card.first.kind == .call ? "Calling" : "Sent") : "Didn't go through"
        return HStack(spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(ok ? JcTheme.success : JcTheme.danger)
                .symbolEffect(.bounce, value: outcome)
            Text(text).font(.headline)
        }
        .frame(maxWidth: .infinity, minHeight: 56)
        .accessibilityElement(children: .combine)
    }
}

/// The person: their Contacts photo, else their initials, else a person glyph.
struct ContactAvatar: View {
    let card: SendConfirmations.Card
    let size: CGFloat

    var body: some View {
        Group {
            if let data = card.photo, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                let initials = SendConfirmations.Card.initials(of: card.name ?? "")
                ZStack {
                    JcTheme.accent.opacity(0.22)
                    if initials.isEmpty {
                        Image(systemName: "person.fill").font(.system(size: size * 0.42))
                    } else {
                        Text(initials).font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                    }
                }
                .foregroundStyle(JcTheme.accent)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(JcTheme.glassBorder, lineWidth: 1))
        .accessibilityHidden(true)
    }
}

/// The same card in a chat, where a typed turn waits on it (agent/send_confirm.py): above the
/// composer like the clarify bar — photo or initials, the name, "Text · +1 209…", the message, and
/// Cancel / Send (Call).
struct ChatSendBar: View {
    let request: ChatSendRequest
    let onAnswer: (Bool) -> Void

    var body: some View {
        let card = request.card
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ContactAvatar(card: card, size: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.title)
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                    Text(card.subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            if !card.message.isEmpty {
                Text(card.message)
                    .font(.subheadline)
                    .lineLimit(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(JcTheme.glassFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(JcTheme.glassBorder, lineWidth: 1))
            }
            HStack(spacing: 10) {
                Button { onAnswer(false) } label: {
                    Text("Cancel").frame(maxWidth: .infinity, minHeight: 24)
                }
                .buttonStyle(.jcGlass(tint: .secondary, full: true))
                Button { onAnswer(true) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: card.actionSymbol)
                        Text(card.actionTitle)
                    }
                    .frame(maxWidth: .infinity, minHeight: 24)
                }
                .buttonStyle(.jcGlass(tint: JcTheme.accent, full: true))
            }
        }
        .padding(14)
        .background(JcTheme.glassFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(JcTheme.glassBorder, lineWidth: 1))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .accessibilityElement(children: .contain)
    }
}
