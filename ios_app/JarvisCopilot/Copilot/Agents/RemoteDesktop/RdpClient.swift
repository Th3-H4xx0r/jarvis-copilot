import CoreGraphics
import Foundation
import Observation
import QuartzCore
#if canImport(FreeRDP)
import FreeRDP
#endif

/// FreeRDP's connect-class errors (include/freerdp/error.h: MAKE_FREERDP_ERROR(CONNECT, x) =
/// (2 << 16) | x), mapped to what he reads. Mirrored here so the mapping is testable without the
/// library; RemoteDesktopTests checks them against the shim when it's linked.
enum RdpErrors {
    static let authenticationFailed: UInt32 = 0x0002_0009
    static let logonFailure: UInt32 = 0x0002_0014
    static let wrongPassword: UInt32 = 0x0002_0015
    static let accountDisabled: UInt32 = 0x0002_0012
    static let passwordExpired: UInt32 = 0x0002_000E
    static let connectFailed: UInt32 = 0x0002_0006
    static let dnsNotFound: UInt32 = 0x0002_0005

    /// nil for a clean end. NLA / logon refusals → the saved-password message.
    static func failure(code: UInt32, message: String, wasConnected: Bool) -> RdpFailure? {
        guard code != 0 else { return nil }
        switch code {
        case authenticationFailed, logonFailure, wrongPassword, passwordExpired: return .passwordRefused
        case accountDisabled: return .other("Windows says this account is disabled")
        default:
            if wasConnected { return .connectionLost }
            let text = message.isEmpty ? "couldn't reach the PC" : message
            return .other("Couldn't connect: \(text)")
        }
    }
}

/// One FreeRDP session: a BGRA framebuffer published as a CGImage, input in, clipboard both ways.
@Observable
final class RdpClient: @unchecked Sendable {
    enum State { case connecting, connected, ended }

    /// The latest desktop picture (main thread).
    private(set) var image: CGImage?
    private(set) var desktopSize = CGSize(width: 0, height: 0)
    /// Frames per second over the last couple of seconds (quality indicator).
    private(set) var fps: Double = 0

    @ObservationIgnored var onState: ((State, RdpFailure?) -> Void)?
    @ObservationIgnored var onClipboard: ((String) -> Void)?

    @ObservationIgnored private let lock = NSLock()
    @ObservationIgnored private var buffer: UnsafeMutableRawPointer?
    @ObservationIgnored private var bufferSize = (w: 0, h: 0)
    @ObservationIgnored private var displayPending = false
    @ObservationIgnored private var frameTimes: [CFTimeInterval] = []
    @ObservationIgnored private var connected = false
    #if canImport(FreeRDP)
    @ObservationIgnored private var session: OpaquePointer?
    #endif

    static var isAvailable: Bool {
        #if canImport(FreeRDP)
        return true
        #else
        return false
        #endif
    }

    func connect(host: String, port: Int, username: String, secret: RdpSecret, width: Int, height: Int,
                 drivePath: String?) throws {
        #if canImport(FreeRDP)
        var callbacks = jrdp_callbacks()
        callbacks.user = Unmanaged.passUnretained(self).toOpaque()
        callbacks.on_frame = { user, bgra, w, h, stride, x, y, dw, dh in
            guard let user, let bgra else { return }
            Unmanaged<RdpClient>.fromOpaque(user).takeUnretainedValue()
                .frame(bgra, Int(w), Int(h), Int(stride), Int(x), Int(y), Int(dw), Int(dh))
        }
        callbacks.on_resize = { user, w, h in
            guard let user else { return }
            let me = Unmanaged<RdpClient>.fromOpaque(user).takeUnretainedValue()
            DispatchQueue.main.async { me.desktopSize = CGSize(width: Int(w), height: Int(h)) }
        }
        callbacks.on_state = { user, state, error, message in
            guard let user else { return }
            Unmanaged<RdpClient>.fromOpaque(user).takeUnretainedValue()
                .stateChanged(Int(state), error, message.map { String(cString: $0) } ?? "")
        }
        callbacks.on_clipboard_text = { user, text in
            guard let user, let text else { return }
            let me = Unmanaged<RdpClient>.fromOpaque(user).takeUnretainedValue()
            let s = String(cString: text)
            DispatchQueue.main.async { me.onClipboard?(s) }
        }
        guard let s = jrdp_create(&callbacks) else { throw RdpCredentialError.noKey }
        session = s
        let (user, domain) = Self.split(username)
        let rc: Int32 = host.withCString { h in user.withCString { u in domain.withCString { d in
            (drivePath ?? "").withCString { dp in "Jarvis iPhone".withCString { dn in
                secret.withCString { p in
                    var cfg = jrdp_config(host: h, port: Int32(port), username: u, password: p,
                                          domain: domain.isEmpty ? nil : d, width: Int32(width), height: Int32(height),
                                          audio: 1, drive_path: drivePath == nil ? nil : dp, drive_name: dn)
                    return jrdp_connect(s, &cfg)
                }
            } }
        } } }
        if rc != 0 { throw RdpCredentialError.badCredential }
        #else
        DispatchQueue.main.async { self.onState?(.ended, .notInThisBuild) }
        #endif
    }

    /// "MicrosoftAccount\\a@b.com" stays whole (RDP wants the prefix in the user name);
    /// "DOMAIN\\user" splits; ".\\user" means a local account.
    static func split(_ username: String) -> (user: String, domain: String) {
        guard let slash = username.firstIndex(of: "\\") else { return (username, "") }
        let domain = String(username[..<slash])
        if domain.caseInsensitiveCompare("MicrosoftAccount") == .orderedSame { return (username, "") }
        let user = String(username[username.index(after: slash)...])
        return (user, domain == "." ? "" : domain)
    }

    private func stateChanged(_ state: Int, _ error: UInt32, _ message: String) {
        DispatchQueue.main.async { [self] in
            switch state {
            case 1: onState?(.connecting, nil)
            case 2:
                connected = true
                onState?(.connected, nil)
            default:
                let failure = RdpErrors.failure(code: error, message: message, wasConnected: connected)
                connected = false
                onState?(.ended, failure)
            }
        }
    }

    /// On FreeRDP's thread: copy the changed rows, then publish once on the main thread.
    private func frame(_ src: UnsafePointer<UInt8>, _ w: Int, _ h: Int, _ stride: Int, _ x: Int, _ y: Int,
                       _ dw: Int, _ dh: Int) {
        lock.lock()
        if bufferSize != (w, h) || buffer == nil {
            buffer?.deallocate()
            buffer = UnsafeMutableRawPointer.allocate(byteCount: w * h * 4, alignment: 16)
            bufferSize = (w, h)
            memcpy(buffer!, src, min(stride, w * 4) * h)   // a resize repaints everything
        }
        let x0 = max(0, x), y0 = max(0, y)
        let x1 = min(w, x + dw), y1 = min(h, y + dh)
        if x1 > x0, y1 > y0 {
            for row in y0..<y1 {
                memcpy(buffer! + row * w * 4 + x0 * 4, src + row * stride + x0 * 4, (x1 - x0) * 4)
            }
        }
        let schedule = !displayPending
        displayPending = true
        lock.unlock()
        if schedule { DispatchQueue.main.async { self.publish() } }
    }

    private func publish() {
        lock.lock()
        displayPending = false
        guard let buffer else { lock.unlock(); return }
        let (w, h) = bufferSize
        let data = Data(bytes: buffer, count: w * h * 4)
        lock.unlock()
        guard let provider = CGDataProvider(data: data as CFData) else { return }
        image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                        provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        if desktopSize != CGSize(width: w, height: h) { desktopSize = CGSize(width: w, height: h) }
        let now = CACurrentMediaTime()
        frameTimes.append(now)
        frameTimes.removeAll { now - $0 > 2 }
        fps = Double(frameTimes.count) / 2
    }

    // MARK: input (queued on FreeRDP's thread by the shim)

    func move(to p: CGPoint) {
        #if canImport(FreeRDP)
        if let session { jrdp_mouse_move(session, Int32(p.x), Int32(p.y)) }
        #endif
    }

    func button(_ button: Int, down: Bool, at p: CGPoint) {
        #if canImport(FreeRDP)
        if let session { jrdp_mouse_button(session, Int32(button), down ? 1 : 0, Int32(p.x), Int32(p.y)) }
        #endif
    }

    func click(_ button: Int = 1, at p: CGPoint) {
        self.button(button, down: true, at: p)
        self.button(button, down: false, at: p)
    }

    func wheel(_ delta: Int, horizontal: Bool, at p: CGPoint) {
        #if canImport(FreeRDP)
        if let session { jrdp_wheel(session, Int32(delta), horizontal ? 1 : 0, Int32(p.x), Int32(p.y)) }
        #endif
    }

    func key(_ key: RdpKeyCode, down: Bool) {
        #if canImport(FreeRDP)
        if let session { jrdp_key(session, Int32(key.scancode), key.extended ? 1 : 0, down ? 1 : 0) }
        #endif
    }

    func tap(_ key: RdpKeyCode) {
        self.key(key, down: true)
        self.key(key, down: false)
    }

    /// Typed text: one Unicode key event per UTF-16 unit.
    func type(_ text: String) {
        #if canImport(FreeRDP)
        guard let session else { return }
        for unit in text.utf16 {
            if unit == 10 { tap(.enter); continue }
            jrdp_unicode(session, Int32(unit), 1)
            jrdp_unicode(session, Int32(unit), 0)
        }
        #endif
    }

    func resize(width: Int, height: Int) {
        #if canImport(FreeRDP)
        if let session { jrdp_resize(session, Int32(width), Int32(height)) }
        #endif
    }

    func setClipboard(_ text: String) {
        #if canImport(FreeRDP)
        if let session { text.withCString { jrdp_clipboard_set_text(session, $0) } }
        #endif
    }

    func disconnect() {
        #if canImport(FreeRDP)
        if let session { jrdp_disconnect(session) }
        #endif
    }

    deinit {
        #if canImport(FreeRDP)
        if let session { jrdp_free(session) }
        #endif
        buffer?.deallocate()
    }
}

/// A PC key as RDP sends it: a set-1 scancode, `extended` for the E0 keys.
struct RdpKeyCode: Equatable, Hashable {
    let scancode: Int
    var extended = false

    static let escape = RdpKeyCode(scancode: 0x01)
    static let tab = RdpKeyCode(scancode: 0x0F)
    static let enter = RdpKeyCode(scancode: 0x1C)
    static let backspace = RdpKeyCode(scancode: 0x0E)
    static let ctrl = RdpKeyCode(scancode: 0x1D)
    static let alt = RdpKeyCode(scancode: 0x38)
    static let shift = RdpKeyCode(scancode: 0x2A)
    static let win = RdpKeyCode(scancode: 0x5B, extended: true)
    static let delete = RdpKeyCode(scancode: 0x53, extended: true)
    static let up = RdpKeyCode(scancode: 0x48, extended: true)
    static let down = RdpKeyCode(scancode: 0x50, extended: true)
    static let left = RdpKeyCode(scancode: 0x4B, extended: true)
    static let right = RdpKeyCode(scancode: 0x4D, extended: true)
    static let c = RdpKeyCode(scancode: 0x2E)
    static let v = RdpKeyCode(scancode: 0x2F)
    static let z = RdpKeyCode(scancode: 0x2C)
    static let a = RdpKeyCode(scancode: 0x1E)
    static let f4 = RdpKeyCode(scancode: 0x3E)
}
