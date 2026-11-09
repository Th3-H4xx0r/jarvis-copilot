import SwiftUI

// His pinned Command Center items on the Mac live view: "I meant buttons from the control center
// menu". Under the picture in portrait (one scrolling row), in the rail's popover in landscape (a
// column). Each item is the sheet's own (`MacControlItem`) and taps go through the same
// `MacControlActions`, so Wi-Fi shows On/Off, Sound has its slider, Now Playing its transport and
// Unlock its Face ID exactly as in the Command Center.

struct MacControlStrip: View {
    enum Layout { case row, column }

    let session: MacScreenSession
    var layout: Layout = .row
    var model: MacControlPinsModel = .shared
    @State private var editing = false
    @State private var sliderOpen: MacControlItem?

    private var actions: MacControlActions { session.controlActions }

    var body: some View {
        let items = model.pins.visible
        VStack(alignment: .leading, spacing: 6) {
            if let why = session.controlError ?? actions.powerError {
                Label { Text(why) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                    .font(.system(size: 12))
                    .foregroundStyle(JcTheme.danger)
                    .lineLimit(2)
                    .padding(.horizontal, layout == .row ? 16 : 0)
                    .transition(.opacity)
            }
            if layout == .row {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(items) { item in compact(item) }
                        editButton(empty: items.isEmpty)
                    }
                    .padding(.horizontal, 16)
                }
                .scrollIndicators(.hidden)
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(items) { item in full(item) }
                        editButton(empty: items.isEmpty)
                    }
                    .padding(14)
                }
                .scrollIndicators(.hidden)
            }
        }
        .padding(.vertical, layout == .row ? 8 : 0)
        .animation(.easeOut(duration: 0.2), value: session.controlError)
        .sheet(isPresented: $editing) { MacControlPinsEditor(model: model) }
        .task { await actions.refreshMac() }
    }

    // MARK: portrait: compact

    @ViewBuilder
    private func compact(_ item: MacControlItem) -> some View {
        let face = actions.face(item)
        switch item.kind {
        case .media:
            HStack(spacing: 6) {
                MacMiniIcon(symbol: face.symbol, on: face.on)
                Text(face.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(JcTheme.text)
                    .lineLimit(1)
                    .frame(maxWidth: 92, alignment: .leading)
                MacTransport(actions: actions, playing: face.on, size: 14, width: 30)
            }
            .padding(.leading, 6)
            .padding(.trailing, 2)
            .frame(height: 48)
            .jcButtonSurface(in: RoundedRectangle(cornerRadius: JcButton.radius, style: .continuous))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Now Playing: \(face.title)")
        case .slider:
            MacMiniTile(face: face, busy: false, enabled: actions.isAvailable(item)) { sliderOpen = item }
                .popover(isPresented: Binding(get: { sliderOpen == item }, set: { if !$0 { sliderOpen = nil } }),
                         arrowEdge: .bottom) {
                    MacSliderRow(item: item, actions: actions)
                        .padding(16)
                        .frame(width: 300)
                        .presentationCompactAdaptation(.popover)
                        .presentationBackground(JcTheme.surface)
                }
                .accessibilityHint("Opens the slider")
        default:
            MacMiniTile(face: face, busy: actions.busy == busyID(item), enabled: actions.isAvailable(item)) {
                actions.perform(item)
            }
        }
    }

    // MARK: landscape: the rail's column

    @ViewBuilder
    private func full(_ item: MacControlItem) -> some View {
        let face = actions.face(item)
        switch item.kind {
        case .media:
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    MacMiniIcon(symbol: face.symbol, on: face.on)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(face.title).font(.system(size: 13, weight: .medium)).foregroundStyle(JcTheme.text).lineLimit(1)
                        Text(face.subtitle ?? "").font(.system(size: 11)).foregroundStyle(JcTheme.muted).lineLimit(1)
                    }
                }
                MacTransport(actions: actions, playing: face.on, size: 16, width: 60)
                    .frame(maxWidth: .infinity)
            }
            .padding(10)
            .jcButtonSurface(in: RoundedRectangle(cornerRadius: JcButton.radius, style: .continuous))
        case .slider:
            MacSliderRow(item: item, actions: actions)
                .padding(10)
                .jcButtonSurface(in: RoundedRectangle(cornerRadius: JcButton.radius, style: .continuous))
                .disabled(!actions.isAvailable(item))
                .opacity(actions.isAvailable(item) ? 1 : JcButton.disabledOpacity)
        default:
            MacMiniTile(face: face, busy: actions.busy == busyID(item), enabled: actions.isAvailable(item),
                        stretch: true) {
                actions.perform(item)
            }
        }
    }

    private func busyID(_ item: MacControlItem) -> String {
        item == .keepAwake ? "keep" : item.rawValue
    }

    private func editButton(empty: Bool) -> some View {
        Button { editing = true } label: {
            HStack(spacing: 6) {
                Image(systemName: empty ? "plus" : "slider.horizontal.3")
                Text(empty ? "Add controls" : "Edit").lineLimit(1)
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(JcTheme.muted)
            .padding(.horizontal, 14)
            .frame(maxWidth: layout == .column ? .infinity : nil)
            .frame(height: layout == .row ? 48 : 40)
            .jcButtonSurface(in: RoundedRectangle(cornerRadius: JcButton.radius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: JcButton.radius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(empty ? "Add Command Center controls" : "Edit pinned controls")
    }
}

/// A small round icon: white with a black glyph when on, grey otherwise (the sheet's tiles).
struct MacMiniIcon: View {
    let symbol: String
    let on: Bool

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(on ? JcAccent.onFill : JcTheme.text)
            .frame(width: 28, height: 28)
            .background(on ? JcAccent.fill : Color.white.opacity(0.08), in: Circle())
            .animation(.snappy(duration: 0.2), value: on)
    }
}

/// A compact tile: icon (state as its fill), name, and the state underneath.
struct MacMiniTile: View {
    let face: MacControlItem.Face
    var busy = false
    var enabled = true
    var stretch = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if busy {
                    ProgressView().controlSize(.small).frame(width: 28, height: 28)
                } else {
                    MacMiniIcon(symbol: face.symbol, on: face.on)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(face.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(JcTheme.text)
                        .lineLimit(1)
                    if let sub = face.subtitle, !sub.isEmpty {
                        Text(sub).font(.system(size: 11)).foregroundStyle(JcTheme.muted).lineLimit(1)
                    }
                }
                .frame(maxWidth: stretch ? .infinity : 110, alignment: .leading)
                .fixedSize(horizontal: !stretch, vertical: false)
                if stretch { Spacer(minLength: 0) }
            }
            .padding(.leading, 6)
            .padding(.trailing, 12)
            .frame(height: stretch ? 44 : 48)
            .frame(maxWidth: stretch ? .infinity : nil, alignment: .leading)
            .jcButtonSurface(in: RoundedRectangle(cornerRadius: JcButton.radius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: JcButton.radius, style: .continuous))
        }
        .buttonStyle(MacPressStyle())
        .disabled(!enabled || busy)
        .opacity(enabled ? 1 : JcButton.disabledOpacity)
        .accessibilityLabel(face.title)
        .accessibilityValue(face.subtitle ?? "")
    }
}

private struct MacPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? JcButton.pressedOpacity : 1)
    }
}

// MARK: - Edit

/// "Live view controls": every Command Center item with a switch, dragged into the order the
/// strip shows them. Kept on this phone (App Group defaults).
struct MacControlPinsEditor: View {
    var model: MacControlPinsModel = .shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let rows = model.pins.rows
        NavigationStack {
            List {
                Section {
                    ForEach(rows) { item in row(item) }
                        .onMove { source, destination in
                            model.update { $0.move(in: rows.map(\.rawValue), from: source, to: destination) }
                        }
                } header: {
                    JcSectionLabel("Command Center", first: true)
                } footer: {
                    Text("Switch on the controls to pin under your Mac's screen. Drag to change their order.")
                        .font(.footnote)
                        .foregroundStyle(JcTheme.muted)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.black)
            .environment(\.editMode, .constant(.active))
            .jcScreen("Live view controls", header: .inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationBackground(.black)
    }

    private func row(_ item: MacControlItem) -> some View {
        HStack(spacing: 12) {
            JcIconSquare(symbol: item.symbol)
            Text(item.title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(JcTheme.text)
                .lineLimit(1)
            Spacer(minLength: 8)
            Toggle(item.title, isOn: Binding(get: { model.pins.isPinned(item) },
                                             set: { on in model.update { $0.set(item, on: on) } }))
                .labelsHidden()
                .toggleStyle(.jcSwitch)
        }
        .listRowBackground(JcTheme.surface)
    }
}
