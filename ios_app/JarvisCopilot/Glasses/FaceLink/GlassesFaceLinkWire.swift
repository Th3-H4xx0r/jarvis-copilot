import Foundation

/// The GO3's AR face recognition ("Face Link", lens app 6). The glasses open the
/// app, ask the phone whether recognition is ready (PREPARE_START_APPLICATION 28,
/// field 31), then send camera images (IMAGE 1, field 4, type AR_IDENTIFY) and
/// show what the phone answers (AR_FACE_RECOGNITION 13, field 16: name, job,
/// company, similarity). The official iPhone app always answers "not ready"
/// (captured 2026-09-27), so the lens asks you to enable permissions. See
/// docs/glasses/go3-face-link.md.
enum GlassesFaceLinkWire {
    /// SWITCHAPP id of face recognition on the lens.
    static let module = 6

    /// Answer to the glasses' "is face recognition ready?". `false` is exactly the
    /// official iPhone app's reply (`101cfa01021200`).
    static func prepared(_ ready: Bool) -> Data {
        InmoCommand.envelope(type: 28, field: 31, payload: InmoWireCodec.bytes(2, InmoWireCodec.uint(1, ready ? 1 : 0)))
    }

    /// Acknowledges one camera image (ImageData.IMAGE_IS_RECEIVED).
    static func imageReceived(timestamp: UInt64) -> Data {
        InmoCommand.envelope(type: 1, field: 4, payload: InmoWireCodec.uint(1, timestamp) + InmoWireCodec.uint(6, 1))
    }

    enum Status: UInt64 { case success = 0, fail = 1, emptyContacts = 2, noMatch = 3 }

    /// A person recognised: the card the lens shows.
    static func identified(name: String, job: String = "", company: String = "", similarity: Float) -> Data {
        var card = InmoWireCodec.string(1, name)
        if !job.isEmpty { card += InmoWireCodec.string(2, job) }
        if !company.isEmpty { card += InmoWireCodec.string(3, company) }
        card += InmoWireCodec.float(7, similarity)
        return InmoCommand.envelope(type: 13, field: 16, payload: card)
    }

    /// Nobody recognised (or nobody enrolled).
    static func notIdentified(_ status: Status) -> Data {
        InmoCommand.envelope(type: 13, field: 16, payload: InmoWireCodec.uint(4, status.rawValue))
    }

    struct Image: Equatable {
        var timestamp: UInt64
        var width: Int
        var height: Int
        var data: Data
        var kind: UInt64
    }

    enum Event: Equatable {
        case opened, closed
        /// The glasses ask whether face recognition is ready.
        case prepareRequested
        case image(Image)
    }

    static func parse(type: Int, fields: [InmoWireField]) throws -> Event? {
        switch type {
        case 15:
            guard let app = try fields.firstField(18)?.nested(), app.firstField(1)?.varint == UInt64(module) else { return nil }
            return (app.firstField(2)?.varint ?? 0) == 1 ? .closed : .opened
        case 28:
            guard let prepare = try fields.firstField(31)?.nested(),
                  (prepare.firstField(1)?.varint ?? 0) == 0,        // AR face recognition
                  prepare.firstField(2) == nil else { return nil }  // a request, not a response
            return .prepareRequested
        case 1:
            guard let image = try fields.firstField(4)?.nested(), let data = image.firstField(4)?.bytes, !data.isEmpty else { return nil }
            return .image(Image(timestamp: image.firstField(1)?.varint ?? 0,
                                width: Int(image.firstField(2)?.varint ?? 0),
                                height: Int(image.firstField(3)?.varint ?? 0),
                                data: data,
                                kind: image.firstField(5)?.varint ?? 0))
        default:
            return nil
        }
    }
}
