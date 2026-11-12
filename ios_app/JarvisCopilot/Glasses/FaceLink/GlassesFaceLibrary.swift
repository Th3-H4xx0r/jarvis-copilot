import SwiftUI
import Observation

/// Every face the glasses' Face Link app detects: the GO3 finds the face itself and sends the phone
/// a small square crop (a ~160–208 px JPEG, AR_IDENTIFY image type 0) while it's in the crosshair.
/// Kept here, newest first. No recognition — just the library.
@MainActor
@Observable
final class GlassesFaceLibrary {
    static let shared = GlassesFaceLibrary()

    struct Face: Identifiable, Hashable {
        let id: String
        let url: URL
        let date: Date
    }

    private(set) var faces: [Face] = []
    /// Oldest faces are dropped past this (~5 KB each).
    static let maxFaces = 500
    let folder: URL

    init(folder: URL? = nil) {
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true)) ?? FileManager.default.temporaryDirectory
        self.folder = folder ?? support.appendingPathComponent("FaceLibrary", isDirectory: true)
        if folder == nil { adoptProbeFaces(from: support.appendingPathComponent("FaceLinkProbe", isDirectory: true)) }
        reload()
    }

    /// Keeps one face crop. Returns it, or nil if it couldn't be written.
    @discardableResult
    func add(_ image: Data, at date: Date = Date()) -> Face? {
        let ext = image.starts(with: [0x89, 0x50, 0x4e, 0x47]) ? "png" : "jpg"
        let id = "\(Int64(date.timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(6).lowercased())"
        let url = folder.appendingPathComponent("\(id).\(ext)")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try image.write(to: url, options: .atomic)
        } catch {
            InmoRuntimeDiagnostics.note("face library could not keep a face: \(error.localizedDescription)")
            return nil
        }
        let face = Face(id: id, url: url, date: date)
        faces.insert(face, at: 0)
        while faces.count > Self.maxFaces { try? FileManager.default.removeItem(at: faces.removeLast().url) }
        return face
    }

    func delete(_ face: Face) {
        try? FileManager.default.removeItem(at: face.url)
        faces.removeAll { $0.id == face.id }
    }

    func clear() {
        for face in faces { try? FileManager.default.removeItem(at: face.url) }
        faces = []
    }

    func reload() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        faces = urls.compactMap { url in
            guard ["jpg", "png"].contains(url.pathExtension.lowercased()) else { return nil }
            let id = url.deletingPathExtension().lastPathComponent
            guard let ms = Int64(id.split(separator: "-").first ?? "") else { return nil }
            return Face(id: id, url: url, date: Date(timeIntervalSince1970: Double(ms) / 1000))
        }
        .sorted { $0.date > $1.date }
    }

    /// The earlier Face Link probe kept the first face crops in FaceLinkProbe; move its JPEGs (the
    /// faces — its PNGs were lens screenshots) into the library once, then drop the folder.
    private func adoptProbeFaces(from probe: URL) {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: probe, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for url in urls where url.pathExtension.lowercased() == "jpg" {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            let id = "\(Int64(date.timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(6).lowercased())"
            try? FileManager.default.moveItem(at: url, to: folder.appendingPathComponent("\(id).jpg"))
        }
        try? FileManager.default.removeItem(at: probe)
    }
}

/// Glasses → Features → Face library: the faces Face Link has seen.
struct GlassesFaceLibraryView: View {
    private let library = GlassesFaceLibrary.shared
    @State private var selected: GlassesFaceLibrary.Face?
    @State private var confirmClear = false
    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 8)]

    var body: some View {
        GlassesSubpage("Face library") {
            GlassesSection(nil, note: "Open Face Link on the glasses and centre a face in the cross: each face the glasses detect is kept here. Nothing is recognised yet, and nothing leaves your iPhone.") {
                if library.faces.isEmpty {
                    Text("No faces yet.")
                        .font(.subheadline).foregroundStyle(JcTheme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                } else {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(library.faces) { face in
                            Button { selected = face } label: { FaceThumb(url: face.url) }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Face seen \(face.date.formatted(date: .abbreviated, time: .shortened))")
                        }
                    }
                    .padding(12)
                }
            }
            if !library.faces.isEmpty {
                Button("Clear face library", role: .destructive) { confirmClear = true }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
        }
        .confirmationDialog("Delete all \(library.faces.count) faces?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Delete all", role: .destructive) { library.clear() }
        }
        .sheet(item: $selected) { face in
            NavigationStack {
                VStack(spacing: 16) {
                    if let image = UIImage(contentsOfFile: face.url.path) {
                        Image(uiImage: image).resizable().interpolation(.high).scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    Text(face.date.formatted(date: .long, time: .standard))
                        .font(.footnote).foregroundStyle(JcTheme.muted)
                    Spacer()
                }
                .padding(20)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Done") { selected = nil } }
                    ToolbarItem(placement: .destructiveAction) {
                        Button("Delete", role: .destructive) { library.delete(face); selected = nil }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }
}

private struct FaceThumb: View {
    let url: URL
    var body: some View {
        Group {
            if let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Color.gray.opacity(0.2)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity)
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
