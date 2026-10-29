import Foundation
import Security

/// A Mac build the server offers (`GET /api/app-updates/latest?platform=mac`,
/// docs/superpowers/specs/2026-10-29-ota-app-updates-design.md).
struct MacAppUpdate: Equatable {
    let build: Int
    let version: String
    let notes: String
    let size: Int
    let installURL: URL

    /// Nil when nothing newer is offered (or the answer is unusable).
    init?(json: [String: Any]) {
        guard J.b(json["available"]), J.s(json["platform"], "mac") == "mac",
              let url = URL(string: J.s(json["install_url"])), url.scheme == "https" else { return nil }
        build = J.i(json["build"])
        version = J.s(json["version"])
        notes = J.s(json["notes"]).trimmingCharacters(in: .whitespacesAndNewlines)
        size = J.i(json["size"])
        installURL = url
        guard build > 0 else { return nil }
    }
}

enum AppUpdateRules {
    /// A build number as a comparable int: `CFBundleVersion` is `date -u +%y%j%H%M`
    /// when build-app.sh stamps it; an unstamped "1" (or anything unreadable)
    /// is older than every published build.
    static func buildNumber(_ raw: Any?) -> Int {
        Int(J.s(raw).trimmingCharacters(in: .whitespaces)) ?? 0
    }

    static var ownBuild: Int { buildNumber(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")) }

    /// Offer only what's newer than what runs — never the same or an older build.
    static func isNewer(_ offered: Int, than installed: Int) -> Bool { offered > installed }

    static func latestURL(origin: String, build: Int) -> URL? {
        URL(string: "\(origin)/api/app-updates/latest?platform=mac&build=\(build)")
    }

    /// Why an unpacked app must not replace this one, or nil when it may: the
    /// same bundle ID as the running app and exactly the build that was offered.
    static func problem(info: [String: Any]?, bundleID: String, build: Int) -> String? {
        guard let info else { return "The download has no Info.plist." }
        guard J.s(info["CFBundleIdentifier"]) == bundleID else {
            return "The download is a different app (\(J.s(info["CFBundleIdentifier"], "unknown")))."
        }
        let got = buildNumber(info["CFBundleVersion"])
        guard got == build else { return "The download is build \(got), not the offered \(build)." }
        return nil
    }

    /// `problem(info:…)` for an unpacked `.app` on disk.
    static func problem(appAt app: URL, bundleID: String, build: Int) -> String? {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        let info = (try? Data(contentsOf: plist)).flatMap {
            try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any]
        }
        return problem(info: info, bundleID: bundleID, build: build)
    }

    /// Why `app`'s signature must not be trusted, or nil when it may: it must
    /// pass a strict check (every architecture, nested code) against the
    /// running app's own designated requirement — same identifier, same Apple
    /// Development certificate — so a validly signed app by anyone else fails.
    /// `own` is the code whose requirement is used (nil: this process).
    static func signatureProblem(appAt app: URL, own: SecStaticCode? = nil) -> String? {
        var me = own
        if me == nil {
            var running: SecCode?
            guard SecCodeCopySelf([], &running) == errSecSuccess, let running,
                  SecCodeCopyStaticCode(running, [], &me) == errSecSuccess else {
                return "Jarvis can't read its own signature, so it can't check the update."
            }
        }
        guard let me else { return "Jarvis can't read its own signature, so it can't check the update." }
        // Unsigned or ad-hoc (no team): there is no certificate to pin to.
        var info: CFDictionary?
        let infoFlags = SecCSFlags(rawValue: UInt32(kSecCSSigningInformation))
        guard SecCodeCopySigningInformation(me, infoFlags, &info) == errSecSuccess,
              let dict = info as? [String: Any], dict[kSecCodeInfoTeamIdentifier as String] != nil,
              (J.i(dict[kSecCodeInfoFlags as String]) & Int(SecCodeSignatureFlags.adhoc.rawValue)) == 0 else {
            return "This copy of Jarvis isn't signed with a developer certificate, so it can't check an update. "
                + "Install it once with mac_app/build-app.sh."
        }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(me, [], &requirement) == errSecSuccess, let requirement else {
            return "Jarvis can't read its own signing requirement, so it can't check the update."
        }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            return "The download isn't a signed app."
        }
        let strict = SecCSFlags(rawValue: UInt32(kSecCSCheckAllArchitectures) | UInt32(kSecCSStrictValidate)
                                    | UInt32(kSecCSCheckNestedCode))
        var error: Unmanaged<CFError>?
        guard SecStaticCodeCheckValidityWithErrors(code, strict, requirement, &error) == errSecSuccess else {
            let why = error.map { CFErrorCopyDescription($0.takeRetainedValue()) as String } ?? "invalid signature"
            return "The download isn't signed by you: \(why)"
        }
        return nil
    }

    /// The detached helper: waits for this app to quit, moves it aside, moves
    /// the new one into its place and opens it; if a move fails or the new app
    /// isn't still running a few seconds after it starts (or 15 s on), whatever
    /// runs from the new copy is stopped and the old one goes back and opens.
    /// Then the work folder goes. Paths are matched as fixed strings (awk
    /// `index`, the path in the environment so the match never sees itself).
    /// Arguments: pid, current bundle, new bundle, backup path, executable
    /// name, work folder.
    static let swapScript = """
    pid="$1"; cur="$2"; new="$3"; bak="$4"; exe="$5"; work="$6"
    case "$work" in */jarvis-update-*) ;; *) work="" ;; esac
    echo "$(date) swap $new -> $cur"
    pids() { ps -axo pid=,command= | P="$cur/Contents/MacOS/$exe" awk 'index($0, ENVIRON["P"]) { print $1 }'; }
    cleanup() { [ -n "$work" ] && rm -rf "$work"; }
    i=0; while kill -0 "$pid" 2>/dev/null && [ $i -lt 300 ]; do sleep 0.2; i=$((i+1)); done
    kill -9 "$pid" 2>/dev/null
    rm -rf "$bak"
    restore() {
      echo "$(date) $1 - restoring"
      p="$(pids)"; [ -n "$p" ] && { kill $p; sleep 1; kill -9 $(pids) 2>/dev/null; }
      rm -rf "$cur"; mv "$bak" "$cur"; open "$cur"; cleanup; exit 1
    }
    mv "$cur" "$bak" || { echo "$(date) couldn't move the old app aside"; open "$cur"; cleanup; exit 1; }
    mv "$new" "$cur" || restore "move failed"
    xattr -dr com.apple.quarantine "$cur" 2>/dev/null
    open "$cur" || restore "open failed"
    i=0; while [ -z "$(pids)" ] && [ $i -lt 15 ]; do sleep 1; i=$((i+1)); done
    sleep 3
    [ -n "$(pids)" ] || restore "the new app isn't running"
    rm -rf "$bak"
    cleanup
    echo "$(date) updated"
    """
}

/// When the pop-up may show. Later puts one build off: it stays hidden on the
/// 15-minute checks and server pushes, and comes back on the next launch (this
/// state is in memory) or the next time the app becomes active 15 minutes on.
/// A newer build than the one put off shows at once.
struct AppUpdateGate {
    static let snooze: TimeInterval = 15 * 60

    enum Trigger { case launch, activation, poll, push }

    private(set) var laterBuild: Int?
    private(set) var laterAt: Date?

    mutating func later(build: Int, at now: Date = Date()) {
        laterBuild = build
        laterAt = now
    }

    func shouldShow(build: Int, trigger: Trigger, now: Date = Date()) -> Bool {
        guard let laterBuild, let laterAt, build <= laterBuild else { return true }
        return trigger == .activation && now.timeIntervalSince(laterAt) >= Self.snooze
    }
}
