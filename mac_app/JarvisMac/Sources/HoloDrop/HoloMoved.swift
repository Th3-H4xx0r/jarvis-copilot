import AppKit
import CoreWLAN
import IOKit.ps

/// Notices this Mac being picked up and carried somewhere else — the lid closed and opened,
/// unplugged or plugged in, a different Wi-Fi access point or a big jump in its signal — and
/// says so (`POST /moved`), so phones forget where they last saw it.
@MainActor
final class HoloMovedWatch {
    var onMoved: ((String) -> Void)?
    private var tokens: [NSObjectProtocol] = []
    private var powerSource: CFRunLoopSource?
    private var wifiTimer: Timer?
    private var lastPower: String?
    private var displays: Set<CGDirectDisplayID> = []
    private var bssid: String?
    private var rssiBaseline: Int?
    private var rssiRecent: [Int] = []
    private var lastSaid = Date.distantPast
    static let quietFor: TimeInterval = 20
    nonisolated static let rssiJump = 15

    var running: Bool { !tokens.isEmpty }

    func start() {
        guard tokens.isEmpty else { return }
        let ws = NSWorkspace.shared.notificationCenter
        tokens.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.say("woke") }
        })
        displays = Self.currentDisplays()
        tokens.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                             object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = Self.currentDisplays()
                if now != self.displays {
                    self.displays = now
                    self.say("displays")
                }
            }
        })
        lastPower = Self.providingPower()
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let watch = Unmanaged<HoloMovedWatch>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { watch.powerChanged() } }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
            powerSource = src
        }
        let iface = CWWiFiClient.shared().interface()
        bssid = iface?.bssid()
        rssiBaseline = iface.map { $0.rssiValue() }.flatMap { $0 == 0 ? nil : $0 }
        wifiTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkWifi() }
        }
    }

    func stop() {
        for t in tokens {
            NotificationCenter.default.removeObserver(t)
            NSWorkspace.shared.notificationCenter.removeObserver(t)
        }
        tokens = []
        if let powerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .defaultMode) }
        powerSource = nil
        wifiTimer?.invalidate()
        wifiTimer = nil
    }

    private func powerChanged() {
        let now = Self.providingPower()
        guard now != lastPower else { return }
        lastPower = now
        say("power")
    }

    private func checkWifi() {
        guard let iface = CWWiFiClient.shared().interface() else { return }
        let rssi = iface.rssiValue()
        let nowBSSID = iface.bssid()   // nil without Location access: then the signal decides alone
        if rssi != 0 {
            rssiRecent = Array((rssiRecent + [rssi]).suffix(3))
        }
        let median = rssiRecent.sorted().dropFirst(rssiRecent.count / 2).first
        if Self.wifiMoved(baselineRSSI: rssiBaseline, currentRSSI: rssiRecent.count >= 3 ? median : nil,
                          bssidBefore: bssid, bssidNow: nowBSSID) {
            rssiBaseline = median ?? rssiBaseline
            bssid = nowBSSID
            rssiRecent = []
            say("wifi")
            return
        }
        if rssiBaseline == nil, let median { rssiBaseline = median }
        if bssid == nil { bssid = nowBSSID }
    }

    /// A different access point, or the signal (median of the last few reads) at least
    /// `rssiJump` dB away from where it settled.
    nonisolated static func wifiMoved(baselineRSSI: Int?, currentRSSI: Int?, bssidBefore: String?,
                                      bssidNow: String?) -> Bool {
        if let a = bssidBefore, let b = bssidNow, !a.isEmpty, !b.isEmpty, a.lowercased() != b.lowercased() { return true }
        if let base = baselineRSSI, let now = currentRSSI, abs(now - base) >= rssiJump { return true }
        return false
    }

    private func say(_ why: String) {
        guard Date().timeIntervalSince(lastSaid) >= Self.quietFor else { return }
        lastSaid = Date()
        onMoved?(why)
    }

    static func currentDisplays() -> Set<CGDirectDisplayID> {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return Set(ids.prefix(Int(count)))
    }

    static func providingPower() -> String? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return nil }
        return type as String
    }
}

/// The Mac's screen for the sender's aiming map: the main display's size and its visible
/// windows' outlines with app names (`POST /screen/<request>`). Window titles are never read.
@MainActor
enum HoloScreenReport {
    static func current() -> [String: Any] {
        let bounds = CGDisplayBounds(CGMainDisplayID())
        let scale = HoloCards.mainScreen?.backingScaleFactor ?? 2
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let me = Int(getpid())
        let windows: [(bounds: CGRect, app: String)] = info.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0, (w[kCGWindowOwnerPID as String] as? Int) != me,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.05,
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: b) else { return nil }
            return (rect, w[kCGWindowOwnerName as String] as? String ?? "")
        }
        return HoloWire.screenReport(width: Double(bounds.width), height: Double(bounds.height), scale: Double(scale),
                                     windows: HoloGeometry.outlines(windows, display: bounds))
    }
}
