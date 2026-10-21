import SwiftUI

/// One tag as a capsule: filled with the accent when it's on.
struct DashcamTagChip: View {
    let name: String
    var on = true
    /// The clip rows' size, under the status line.
    var small = false

    var body: some View {
        Text(name)
            .font(small ? .caption2.weight(.semibold) : .subheadline.weight(.semibold))
            .lineLimit(1)
            .foregroundStyle(on ? JcTheme.accent : .secondary)
            .padding(.horizontal, small ? 7 : 12)
            .padding(.vertical, small ? 2 : 7)
            .background(Capsule().fill(on ? JcTheme.accent.opacity(0.18) : Color.white.opacity(0.06)))
            .overlay(Capsule().stroke(on ? JcTheme.accent.opacity(0.45) : Color.white.opacity(0.1), lineWidth: 1))
    }
}

/// A clip row's tags: as many whole chips as fit, then "+N" for the rest.
struct DashcamClipTags: View {
    let tags: [String]
    @ObservedObject private var store = DashcamTagStore.shared

    var body: some View {
        if !tags.isEmpty {
            ViewThatFits(in: .horizontal) {
                ForEach((1...tags.count).reversed(), id: \.self) { shown in chips(shown) }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Tags: " + tags.map(store.name).joined(separator: ", "))
        }
    }

    private func chips(_ shown: Int) -> some View {
        HStack(spacing: 4) {
            ForEach(tags.prefix(shown), id: \.self) { DashcamTagChip(name: store.name($0), small: true).fixedSize() }
            if tags.count > shown {
                Text("+\(tags.count - shown)").font(.caption2.weight(.semibold)).foregroundStyle(.secondary).fixedSize()
            }
        }
    }
}

/// The clip page's Tags: every tag a chip, tap to put it on or take it off — the other camera's clip of the
/// same moment follows — + New tag, and Delete on his own tags (long press).
struct DashcamTagsCard: View {
    @ObservedObject var model: DashcamPlayerModel
    /// The other lens's page model in Both, to show what the server set on it.
    var partner: DashcamPlayerModel?
    @ObservedObject private var store = DashcamTagStore.shared
    @State private var naming = false
    @State private var newName = ""
    @State private var deleting: DashcamTag?
    @State private var problem: String?

    var body: some View {
        CardGroup("Tags") {
            Row {
                VStack(alignment: .leading, spacing: 8) {
                    JcWrap(spacing: 8, runSpacing: 8) {
                        ForEach(store.tags) { tag in
                            Button { toggle(tag.id) } label: { DashcamTagChip(name: tag.name, on: model.clip.tags.contains(tag.id)) }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(model.clip.tags.contains(tag.id) ? .isSelected : [])
                                .contextMenu {
                                    if !tag.preset {
                                        Button(role: .destructive) { deleting = tag } label: { Label("Delete tag", systemImage: "trash") }
                                    }
                                }
                        }
                        Button { newName = ""; naming = true } label: {
                            Label("New tag", systemImage: "plus").labelStyle(.titleAndIcon)
                                .font(.subheadline.weight(.semibold)).foregroundStyle(JcTheme.accent)
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .overlay(Capsule().stroke(JcTheme.accent.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                        }
                        .buttonStyle(.plain)
                    }
                    if let problem {
                        Text(problem).font(.caption).foregroundStyle(JcTheme.danger)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .task { await store.load() }
        .alert("New tag", isPresented: $naming) {
            TextField("Name", text: $newName)
            Button("Add") { addAndApply(newName) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It goes on this clip, and is there to pick from now on.")
        }
        .alert("Delete \"\(deleting?.name ?? "")\"?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) { if let tag = deleting { remove(tag) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It comes off every clip that has it. The clips stay.")
        }
    }

    /// Shown at once; put back if the server says no.
    private func toggle(_ id: String) {
        let before = model.clip.tags
        apply(DashcamTagging.toggled(before, id), before: before)
    }

    private func apply(_ wanted: [String], before: [String]) {
        let clip = model.clip
        model.clip.tags = wanted
        problem = nil
        Task {
            do {
                let clips = try await store.set(wanted, on: clip)
                for c in clips {
                    if c.id == model.clip.id { model.clip.tags = c.tags }
                    if let partner, c.id == partner.clip.id { partner.clip.tags = c.tags }
                }
                DashcamLibraryModel.shared.adopt(clips)
            } catch {
                if model.clip.id == clip.id { model.clip.tags = before }
                problem = "Couldn't save the tag: \(error.localizedDescription)"
            }
        }
    }

    private func addAndApply(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        Task {
            do {
                let tag = try await store.add(name)
                let before = model.clip.tags
                if !before.contains(tag.id) { apply(before + [tag.id], before: before) }
            } catch {
                problem = "Couldn't add the tag: \(error.localizedDescription)"
            }
        }
    }

    private func remove(_ tag: DashcamTag) {
        Task {
            do {
                try await store.delete(tag.id)
                model.clip.tags.removeAll { $0 == tag.id }
                partner?.clip.tags.removeAll { $0 == tag.id }
                if DashcamLibraryModel.shared.tag == tag.id { DashcamLibraryModel.shared.tag = nil }
                await DashcamLibraryModel.shared.refresh()
            } catch {
                problem = "Couldn't delete the tag: \(error.localizedDescription)"
            }
        }
    }
}
