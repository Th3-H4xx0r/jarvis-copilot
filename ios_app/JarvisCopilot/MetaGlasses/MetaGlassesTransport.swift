import Combine
import CoreBluetooth
import Foundation

/// CoreBluetooth transport shell for the Ray-Ban Meta (Gen 2) glasses.
///
/// SCAFFOLDING ONLY. This documents the known BLE link specifics from the protocol plan
/// (`docs/glasses/2026-11-21-meta-glasses-protocol-plan.md`, §4 and §5.1) as code structure
/// plus TODOs. It implements **no** AirShield handshake, **no** crypto, and **no** credential
/// or ownership handling (that is §5.2/§5.3, deliberately not reproduced here). The
/// `CBCentralManager` is created lazily in `start()`, which nothing calls yet, so this type
/// performs **no** Bluetooth activity and triggers no permission prompt until a later phase
/// wires it in. Mirrors the shape of `Glasses/Connection/InmoSession.swift` at a far smaller scale.
@MainActor
final class MetaGlassesTransport: NSObject, ObservableObject, GlassesTransport, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    static let shared = MetaGlassesTransport()

    // MARK: Known link specifics (plan §4 / §5.1) — single-sourced from the public Visor spec.

    /// GATT service the glasses advertise; carries the one encrypted L2CAP session.
    static let serviceUUID = CBUUID(string: "FD5F")
    /// Characteristic whose value is the dynamic L2CAP PSM to open.
    static let psmCharacteristicUUID = CBUUID(string: "05acbe9f-6f61-4ca9-80bf-c8bbb52991c0")
    /// BLE manufacturer-data company identifier (Meta), used to spot the glasses in a scan.
    static let companyIdentifier: UInt16 = 0x01AB
    /// PSM read from `psmCharacteristicUUID`; on Gen 2 it reads 128 (0x80). The audio-only
    /// "orca" model reads 129 instead.
    /// TODO(plan §5.1): NEVER hard-code the PSM — always read the characteristic. This is the
    /// expected Gen-2 value for reference only.
    static let expectedGen2PSM: UInt16 = 128

    enum State: String {
        case idle, poweredOff, unauthorized, scanning, connecting, discovering, openingChannel, ready, failed
    }
    @Published private(set) var state: State = .idle

    var isReady: Bool { state == .ready }

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var channel: CBL2CAPChannel?

    // MARK: GlassesTransport inbound (skeleton — nothing is decoded into it yet)
    let inbound: AsyncStream<GlassesInboundEvent>
    private let inboundContinuation: AsyncStream<GlassesInboundEvent>.Continuation

    private override init() {
        var cont: AsyncStream<GlassesInboundEvent>.Continuation!
        inbound = AsyncStream(bufferingPolicy: .unbounded) { cont = $0 }
        inboundContinuation = cont
        super.init()
    }

    /// Bring the central up. NOT called during scaffolding — wiring this in is a later phase.
    ///
    /// TODO(plan §5.1): bonded glasses stop advertising, so `retrievePeripherals(withIdentifiers:)`
    /// the stored peripheral and auto-connect, discover `serviceUUID`, read `psmCharacteristicUUID`,
    /// then `CBPeripheral.openL2CAPChannel(_:)`. CoreBluetooth opens BLE L2CAP channels without
    /// MFi / External-Accessory approval. Validate background behaviour of an open channel
    /// across suspension (plan §5.1, UNVERIFIED on iOS).
    func start() {
        guard central == nil else { return }
        central = CBCentralManager(delegate: self, queue: nil)
        // State machine continues from centralManagerDidUpdateState(_:).
    }

    /// Tear everything down and release the link.
    func stop() {
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        channel = nil
        peripheral = nil
        central = nil
        state = .idle
    }

    /// Retrieve the already-bonded glasses by their stored CoreBluetooth identifier and connect.
    /// TODO(plan §5.1): persist the identifier on first pair; then `retrievePeripherals` + `connect`.
    private func connectKnownPeripheral() {
        // TODO: implement in Phase 1.
    }

    /// Open the connection-oriented L2CAP channel once the PSM has been read.
    /// TODO(plan §5.1): `peripheral.openL2CAPChannel(psm)`, then hand the channel's streams to the
    /// AirShield session (plan §5.2 — handshake + owner trust), which is intentionally NOT built here.
    private func openChannel(psm: CBL2CAPPSM) {
        // TODO: implement in Phase 1 (transport); Phase 0 proves it on macOS first.
    }

    // MARK: GlassesTransport (skeleton — NOT wired to live Bluetooth; see the class doc)

    /// Map the internal BLE bring-up state onto the transport-agnostic link state.
    var linkState: GlassesLinkState {
        switch state {
        case .idle: return .disconnected
        case .poweredOff, .unauthorized, .failed: return .failed(state.rawValue)
        case .scanning, .connecting, .discovering: return .connecting
        case .openingChannel: return .connected
        case .ready: return .ready
        }
    }

    /// TODO(plan §5.1/§5.2): bring up the BLE L2CAP channel (retrievePeripherals → discover
    /// 0xFD5F → read the PSM characteristic → openL2CAPChannel), then run the AirShield handshake
    /// + owner trust, and start decoding sealed frames into `inboundContinuation`. The real
    /// encrypted transport is hardware-gated and cannot be verified without the physical glasses,
    /// so it is intentionally not implemented here (NO fake crypto, NO Meta tokens).
    func connect() async throws {
        throw MetaGlassesError.transportUnavailable("real CoreBluetooth L2CAP + AirShield transport is not implemented (hardware-gated)")
    }

    /// TODO(plan §5.2): seal `frame` into an AirShield record and write it to the L2CAP channel.
    func send(_ frame: GlassesFrame) async throws {
        throw MetaGlassesError.transportUnavailable("real AirShield frame send is not implemented (hardware-gated)")
    }

    func disconnect() async {
        stop()
        inboundContinuation.finish()
    }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        // TODO(plan §5.1): on .poweredOn, retrieve the bonded peripheral and connect.
        switch central.state {
        case .poweredOff: state = .poweredOff
        case .unauthorized: state = .unauthorized
        default: break
        }
    }

    // MARK: CBPeripheralDelegate

    /// TODO(plan §5.1): didDiscoverServices → discover characteristics → read PSM → `openChannel`.
    func peripheral(_ peripheral: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
        // TODO(plan §5.2): hand the opened channel's input/output streams to the AirShield session
        // (not built in scaffolding). No crypto or owner trust is performed here.
    }
}
