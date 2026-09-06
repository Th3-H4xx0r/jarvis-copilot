import Foundation

/// Body for `POST /api/devices/mobile/poll`. The server uses `foreground` to
/// decide whether to hand out foreground-required invokes (true) or withhold
/// them so a background wake never runs a foreground action headless (false).
///
/// Port of `mobile_client/lib/services/poll_body.dart`.
func pollBody(foreground: Bool) -> [String: Any] {
    ["foreground": foreground]
}
