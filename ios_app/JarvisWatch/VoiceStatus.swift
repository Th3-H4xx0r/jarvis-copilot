import Combine
import Foundation

/// Tiny observable the watch shows under the answer so audio behaviour is
/// visible ON THE WATCH (no Console.app needed) while we debug "no voice".
@MainActor
final class VoiceStatus: ObservableObject {
    static let shared = VoiceStatus()
    @Published var note: String = ""
    func set(_ s: String) { note = s }
}
