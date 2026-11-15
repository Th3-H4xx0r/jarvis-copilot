import AppKit
import SwiftUI

/// Share → Jarvis on the Mac: the same Orbit popup as the app's Holo Drop, for whatever was
/// shared (a page, photos, videos, files, text). The extension's sandbox can't reach jc-client,
/// so it reads the loopback proxy's address from the file the app keeps
/// (`~/.jarviscopilot-client/holo-share.json`) and talks to Jarvis through it — no credentials
/// of its own.
final class ShareViewController: NSViewController {
    private let model = HoloOrbitModel()
    private var api: HoloDropAPI?
    private var done = false

    override var nibName: NSNib.Name? { nil }

    override func loadView() {
        let host = NSHostingView(rootView: HoloOrbitView(model: model).environment(\.colorScheme, .dark))
        host.frame = CGRect(origin: .zero, size: HoloOrbitView.size)
        view = host
        preferredContentSize = HoloOrbitView.size
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        HoloTemp.sweep()   // this extension's own leftovers older than a day
        model.onClose = { [weak self] in self?.finish(sent: false) }
        model.onSend = { [weak self] device, action in self?.send(to: device, action: action) }
        let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
        let providers = items.flatMap { $0.attachments ?? [] }
        let caption = items.first?.attributedContentText?.string
        Task { @MainActor [weak self] in
            guard let self else { return }
            var item = await HoloItemLoader.load(providers, copyFiles: true)
            if item == nil, let caption { item = HoloItem.fromText(caption) }
            self.model.setItem(item)
        }
        let info = HoloShareInfo.read()
        guard let origin = info.api else {
            model.loading = false
            model.phase = .unavailable("Open Jarvis on this Mac, then share again")
            return
        }
        if info.on == false {
            model.loading = false
            model.phase = .off
            return
        }
        let api = HoloDropAPI(origin: origin)
        self.api = api
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                self.model.devices = try await api.devices()
            } catch HoloFailure.off {
                self.model.phase = .off
            } catch {
                self.model.phase = .unavailable("Jarvis isn't reachable right now")
            }
            self.model.loading = false
        }
    }

    private func send(to device: HoloDevice, action: HoloAction) {
        guard let api, let item = model.item else { return }
        model.phase = .sending(device.name)
        model.onRetry = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let sent = try await HoloSender(api: api).send(item, to: device, action: action)
                if let outcome = sent.outcome, sent.ids.isEmpty {
                    let line = HoloDropRecord.landedLine(device: device.name, outcome: outcome.rawValue, error: sent.error)
                    if outcome == .failed {
                        // The receiver took it and couldn't land it: say so, never resend by itself.
                        self.model.phase = .failed(line)
                        self.model.onRetry = { [weak self] in self?.send(to: device, action: action) }
                        return
                    }
                    self.model.phase = .landed(line)
                } else {
                    self.model.phase = .waiting(device.online ? "Sent — waiting for \(device.name)"
                                                              : "\(device.name) is away — it lands when it's back")
                    if let last = sent.ids.last, let d = await api.waitLanded(last, timeout: 4) {
                        self.model.phase = .landed(HoloDropRecord.landedLine(device: device.name, outcome: d.outcome))
                    }
                }
                try? await Task.sleep(for: .seconds(1.6))
                self.finish(sent: true)
            } catch HoloFailure.off {
                self.model.phase = .off
            } catch {
                let why = (error as? HoloFailure)?.message ?? error.localizedDescription
                self.model.phase = .failed("Couldn't send — \(why)")
                self.model.onRetry = { [weak self] in self?.send(to: device, action: action) }
            }
        }
    }

    private func finish(sent: Bool) {
        guard !done else { return }
        done = true
        HoloTemp.release(model.item)   // the copies made from what was shared
        if sent {
            extensionContext?.completeRequest(returningItems: nil)
        } else {
            extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
        }
    }
}

/// What the Jarvis app leaves for this extension: the loopback proxy's origin and whether Holo
/// Drop is on.
enum HoloShareInfo {
    static func read() -> (api: String?, on: Bool?) {
        // The real home folder, not this extension's container.
        guard let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir else { return (nil, nil) }
        let path = String(cString: dir) + "/.jarviscopilot-client/holo-share.json"
        guard let data = FileManager.default.contents(atPath: path),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return (nil, nil) }
        let api = HJ.s(obj["api"])
        return (api.isEmpty ? nil : api, obj["on"] == nil ? nil : HJ.b(obj["on"]))
    }
}
