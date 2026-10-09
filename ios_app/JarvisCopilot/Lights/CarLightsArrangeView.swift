import SceneKit
import SwiftUI

/// Arrange lamps: put the car's lamps where they really are, on the cut-away Camry. Spot: tap the
/// cabin. Strip: drag from one end to the other. Select: tap a lamp to rename or delete it, drag
/// it to move it. Saved on the phone; Reset goes back to the default layout.
struct CarLightsArrangeView: View {
    enum Tool: String, CaseIterable, Identifiable {
        case select = "Select", spot = "Spot", strip = "Strip"
        var id: String { rawValue }
        var hint: String {
            switch self {
            case .select: return "Tap a lamp to pick it · drag it to move it"
            case .spot: return "Tap the cabin to add a spot lamp"
            case .strip: return "Drag from one end of a strip to the other"
            }
        }
    }

    @ObservedObject private var store: CarLightLayoutStore = .shared
    @Environment(\.dismiss) private var dismiss
    @State private var tool: Tool = .select
    @State private var selected: String?
    @State private var stripStart: SIMD3<Float>?
    @State private var draft: CarLightLayout.Lamp?
    @State private var dragLast: SIMD3<Float>?
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmReset = false
    @State private var note: String?

    /// The layout with a strip still being drawn.
    private var shown: CarLightLayout {
        var layout = store.layout
        if let draft { layout.lamps.append(draft) }
        return layout
    }

    private var selectedLamp: CarLightLayout.Lamp? { store.layout.lamps.first { $0.id == selected } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                CarLightsPreview(layout: shown, look: .solid(MelkColor(r: 70, g: 200, b: 255), brightness: 100),
                                 selected: selected, onTap: tap, onPan: pan)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Text(note ?? tool.hint).font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $tool) {
                    ForEach(Tool.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)
                if let lamp = selectedLamp {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(lamp.name).font(.body.weight(.semibold))
                            Text(lamp.from != nil ? "Strip" : "Spot").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Rename") { newName = lamp.name; renaming = true }.buttonStyle(.jcGlass(compact: true))
                        Button("Delete", role: .destructive) {
                            store.remove(lamp.id)
                            selected = nil
                        }
                        .buttonStyle(.jcGlass(tint: JcTheme.danger, compact: true))
                    }
                    .padding(14)
                    .background(JcTheme.glassFill, in: RoundedRectangle(cornerRadius: JcTheme.cardRadius, style: .continuous))
                    .padding(.horizontal, 16)
                }
            }
            .padding(.bottom, 12)
            .background(JcTheme.bg.ignoresSafeArea())
            .navigationTitle("Arrange lamps · \(store.layout.lamps.count)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Menu {
                        Button("Reset to the default layout", jcIcon: "arrow.counterclockwise") { confirmReset = true }
                            .disabled(!store.customised)
                    } label: { JcIcon("ellipsis").foregroundStyle(JcTheme.accent) }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .alert("Rename lamp", isPresented: $renaming) {
                TextField("Name", text: $newName)
                Button("Cancel", role: .cancel) {}
                Button("Save") { if let selected { store.rename(selected, to: newName) } }
            }
            .confirmationDialog("Put every lamp back where it started?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Reset layout", role: .destructive) { store.reset(); selected = nil }
            }
            .onChange(of: tool) { _, _ in note = nil; draft = nil; stripStart = nil }
        }
    }

    private func tap(_ point: CGPoint, _ view: SCNView, _ scene: CarLightsScene) {
        note = nil
        switch tool {
        case .select:
            selected = scene.lamp(near: point, in: view)
        case .spot:
            guard let p = scene.cabinPoint(at: point, in: view) else { note = "Tap inside the cabin"; return }
            selected = store.add(.point(p))
        case .strip:
            note = "Drag to draw a strip"
        }
    }

    private func pan(_ recognizer: UIPanGestureRecognizer, _ scene: CarLightsScene) {
        guard let view = recognizer.view as? SCNView else { return }
        let location = recognizer.location(in: view)
        switch tool {
        case .strip:
            switch recognizer.state {
            case .began:
                stripStart = scene.cabinPoint(at: location, in: view)
                if stripStart == nil { note = "Start the strip inside the cabin" }
            case .changed:
                guard let start = stripStart, let end = scene.cabinPoint(at: location, in: view) else { return }
                draft = .strip(id: "draft", name: "New strip", from: start, to: end)
            case .ended:
                if let start = stripStart, let end = scene.cabinPoint(at: location, in: view) ?? draftEnd,
                   simd_distance(start, end) > 0.05 {
                    selected = store.add(.strip(start, end), name: "Strip \(store.layout.lamps.count + 1)")
                }
                draft = nil
                stripStart = nil
            default:
                draft = nil
                stripStart = nil
            }
        case .select:
            switch recognizer.state {
            case .began:
                if let hit = scene.lamp(near: location, in: view) { selected = hit }
                dragLast = selected == nil ? nil : scene.cabinPoint(at: location, in: view)
            case .changed:
                guard let id = selected, let last = dragLast, let p = scene.cabinPoint(at: location, in: view) else { return }
                store.move(id, by: p - last, persist: false)
                dragLast = p
            default:
                if dragLast != nil { store.commit() }
                dragLast = nil
            }
        case .spot:
            break
        }
    }

    private var draftEnd: SIMD3<Float>? {
        if case .strip(_, let end) = draft?.shape { return end }
        return nil
    }
}
