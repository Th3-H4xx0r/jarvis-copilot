import SwiftUI

/// An item's picture: the server-made (or phone-made) thumbnail, or a drawn stand-in for a
/// note, a PDF without one, or a plain file. Decrypted bytes live in `VaultSession`'s memory
/// cache only.
struct VaultThumb: View {
    let item: VaultItem
    @ObservedObject var session: VaultSession
    var small = false
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            JcTheme.surfaceAlt
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else {
                standIn
            }
        }
        .clipped()
        .task(id: "\(item.id)-\(item.updated.timeIntervalSince1970)-\(item.hasThumb)-\(item.thumbAspect ?? 0)") {
            guard item.hasThumb else { return }
            let loaded = await session.thumbnail(for: item)
            withAnimation(.easeOut(duration: 0.18)) { image = loaded }
        }
    }

    @ViewBuilder
    private var standIn: some View {
        switch item.kind {
        case .note:
            VStack(alignment: .leading, spacing: small ? 2 : 6) {
                Text(item.displayTitle)
                    .font(.system(size: small ? 8 : 13, weight: .semibold))
                    .foregroundStyle(JcTheme.text)
                    .lineLimit(1)
                Text(item.snippet)
                    .font(.system(size: small ? 7 : 12))
                    .foregroundStyle(JcTheme.text.opacity(0.7))
                    .lineSpacing(small ? 0 : 2)
            }
            .padding(small ? 6 : 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .pdf:
            VStack(alignment: .leading, spacing: small ? 3 : 5) {
                Capsule().fill(Color.black.opacity(0.45)).frame(width: small ? 20 : 54, height: small ? 3 : 7)
                ForEach(0..<6, id: \.self) { i in
                    Capsule().fill(Color.black.opacity(0.18)).frame(height: small ? 2 : 4)
                        .padding(.trailing, i % 3 == 2 ? (small ? 10 : 30) : 0)
                }
            }
            .padding(small ? 6 : 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color(white: 0.95))
            .padding(.horizontal, small ? 18 : 22)
            .padding(.top, small ? 6 : 14)
        default:
            VStack(spacing: 8) {
                JcIcon(item.symbol, size: small ? 18 : 30).foregroundStyle(JcTheme.muted)
                if !small, item.kind == .file {
                    Text(item.fileExtension.uppercased())
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(JcTheme.text)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(JcButton.fill, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
            }
        }
    }
}

/// The duration chip in a thumbnail's corner, like a search result's video.
struct VaultDurationChip: View {
    let text: String
    var small = false
    var body: some View {
        Text(text)
            .font(.system(size: small ? 10 : 11, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, small ? 4 : 6)
            .padding(.vertical, small ? 1 : 2)
            .background(Color.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .padding(small ? 4 : 8)
    }
}

/// The round play mark over a video's thumbnail.
struct VaultPlayBadge: View {
    var size: CGFloat = 46
    var body: some View {
        JcIcon("play.fill", size: size * 0.42)
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(.ultraThinMaterial, in: Circle())
            .environment(\.colorScheme, .dark)
    }
}

/// A grid tile: square thumbnail (video links full-width at 16:9), title, meta line.
struct VaultGridCard: View {
    let item: VaultItem
    @ObservedObject var session: VaultSession
    var selecting = false
    var selected = false

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 18, style: .continuous) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .aspectRatio(item.isWide ? 16 / 9 : 1, contentMode: .fit)
                .overlay { VaultThumb(item: item, session: session) }
                .overlay { if item.isWide { VaultPlayBadge() } }
                .overlay(alignment: .bottomTrailing) {
                    if item.kind == .video || item.isWide, let d = VaultFormat.duration(item.duration) {
                        VaultDurationChip(text: d)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if item.kind == .link, !item.isWide { badge("link", item.link?.domain ?? "Link") }
                    if item.kind == .video { badge("video.fill", "VIDEO") }
                }
                .clipped()
            VStack(alignment: .leading, spacing: 3) {
                Text(item.displayTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(JcTheme.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(item.path ?? item.metaLine)
                    .font(.system(size: 12))
                    .foregroundStyle(JcTheme.muted)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(JcTheme.glassFill, in: shape)
        .overlay(shape.strokeBorder(selected ? JcTheme.text : JcTheme.border, lineWidth: selected ? 2 : 1))
        .clipShape(shape)
        .overlay(alignment: .topTrailing) {
            if selecting { VaultCheck(on: selected).padding(8) }
        }
        .contentShape(shape)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func badge(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            JcIcon(symbol, size: 10)
            Text(text).lineLimit(1)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .padding(8)
    }
}

/// A list row: the thumbnail on the left with its duration chip, the way search results look.
struct VaultListRow: View {
    let item: VaultItem
    @ObservedObject var session: VaultSession
    var selecting = false
    var selected = false
    var last = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VaultThumb(item: item, session: session, small: true)
                    .frame(width: 86, height: 56)
                    .overlay(alignment: .bottomTrailing) {
                        if item.kind == .video || item.isWide, let d = VaultFormat.duration(item.duration) {
                            VaultDurationChip(text: d, small: true)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.displayTitle)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(JcTheme.text)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(item.path ?? (item.kind == .note ? item.metaLine : item.metaLine + " · " + VaultFormat.day(item.updated)))
                        .font(.system(size: 12))
                        .foregroundStyle(JcTheme.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if selecting { VaultCheck(on: selected) } else { JcRowChevron() }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            if !last { JcRowSeparator(inset: 110) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A folder in a card of rows, the Files / Settings way: icon square, name, count, chevron.
struct VaultFolderRow: View {
    let folder: VaultFolder
    var last = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                JcIconSquare(symbol: "folder.fill", tint: JcTheme.text)
                Text(folder.name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(JcTheme.text)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(folder.count == 1 ? "1 item" : "\(folder.count) items")
                    .font(.system(size: 14))
                    .foregroundStyle(JcTheme.muted)
                    .monospacedDigit()
                JcRowChevron()
            }
            .padding(.horizontal, JcUnified.cardPadding)
            .padding(.vertical, 12)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
            if !last { JcRowSeparator(inset: 56) }
        }
        .accessibilityElement(children: .combine)
    }
}

struct VaultCheck: View {
    let on: Bool
    var body: some View {
        ZStack {
            Circle().fill(on ? JcTheme.text : Color.black.opacity(0.35))
            Circle().strokeBorder(JcTheme.text, lineWidth: 2)
            if on { JcIcon("checkmark", size: 11, weight: .bold).foregroundStyle(JcTheme.bg) }
        }
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
    }
}
