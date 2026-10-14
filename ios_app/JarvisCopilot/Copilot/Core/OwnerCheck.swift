import LocalAuthentication

/// "Is it really you?" before something runs on a computer from the phone:
/// allowing a command, sending an instruction, a service action. Face ID, with
/// the passcode as fallback (a phone without Face ID still works).
enum OwnerCheck {
    static func confirm(reason: String) async -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // No passcode at all: there's nothing to check against.
            return error.map { LAError.Code(rawValue: $0.code) == .passcodeNotSet } ?? false
        }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication,
                                                  localizedReason: reason)) ?? false
    }
}
