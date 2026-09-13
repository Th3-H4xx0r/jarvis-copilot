import Foundation

/// This library's resource bundle, found the only way that survives shipping.
///
/// NOT `Bundle.module`. SwiftPM generates that accessor to look in exactly two
/// places, and for a dylib loaded by someone else's process both are wrong:
///
///  * beside `Bundle.main` — which here is the PYTHON TRAY that loaded us, and
///    has no idea this bundle exists;
///  * an absolute path into `.build/` on whichever machine compiled the library.
///
/// The second is the dangerous one: it makes `Bundle.module` work on the build
/// machine and only there, so the miss never shows up until someone else
/// installs it — and the generated accessor answers a miss with `fatalError`,
/// which would take the tray process down with it.
///
/// `dladdr` asks the dynamic linker where this code was actually loaded from,
/// which is true wherever the dylib ends up. `build.sh` puts the bundle beside
/// the dylib for exactly this lookup.
let macVoiceResourceBundle: Bundle? = {
    // A capture-less `@convention(c)` closure is a plain function compiled into
    // this library, so its address is an address inside this library's image.
    let anchor: @convention(c) () -> Void = {}
    var info = Dl_info()
    guard dladdr(unsafeBitCast(anchor, to: UnsafeRawPointer.self), &info) != 0,
          let path = info.dli_fname else {
        JcLog.voice.error("mac voice: dladdr could not locate the dylib; the orb will not draw")
        return nil
    }
    let url = URL(fileURLWithPath: String(cString: path))
        .deletingLastPathComponent()
        .appendingPathComponent("JarvisVoiceUI_JarvisVoiceUI.bundle")
    guard let bundle = Bundle(url: url) else {
        JcLog.voice.error("""
            mac voice: no resource bundle at \(url.path, privacy: .public) \
            — run mac_app/build.sh; the orb will not draw
            """)
        return nil
    }
    return bundle
}()
