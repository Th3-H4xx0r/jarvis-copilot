import Security
import SwiftUI
import WebKit

// MARK: - Settings

/// The private browser's switches ("Jarvis Shields").
struct VaultShieldSettings: Codable, Equatable {
    var enabled = true
    var blockAds = true
    var hideAdSpaces = true
    var blockPopups = true
    /// Fake the signs ad-block detectors look for, so "turn off your ad blocker" walls stay down.
    var stealth = true
    var blockAutoplay = true
    var javascript = true
    var globalPrivacyControl = true
    var search: VaultSearchEngine = .duckDuckGo

    init() {}

    // Tolerates settings saved by an older build (missing keys keep their defaults).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = VaultShieldSettings()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        blockAds = try c.decodeIfPresent(Bool.self, forKey: .blockAds) ?? d.blockAds
        hideAdSpaces = try c.decodeIfPresent(Bool.self, forKey: .hideAdSpaces) ?? d.hideAdSpaces
        blockPopups = try c.decodeIfPresent(Bool.self, forKey: .blockPopups) ?? d.blockPopups
        stealth = try c.decodeIfPresent(Bool.self, forKey: .stealth) ?? d.stealth
        blockAutoplay = try c.decodeIfPresent(Bool.self, forKey: .blockAutoplay) ?? d.blockAutoplay
        javascript = try c.decodeIfPresent(Bool.self, forKey: .javascript) ?? d.javascript
        globalPrivacyControl = try c.decodeIfPresent(Bool.self, forKey: .globalPrivacyControl) ?? d.globalPrivacyControl
        search = (try? c.decodeIfPresent(VaultSearchEngine.self, forKey: .search)) ?? d.search
    }
}

enum VaultSearchEngine: String, Codable, CaseIterable, Identifiable {
    case duckDuckGo, startpage, brave, google
    var id: String { rawValue }

    var name: String {
        switch self {
        case .duckDuckGo: return "DuckDuckGo"
        case .startpage: return "Startpage"
        case .brave: return "Brave Search"
        case .google: return "Google"
        }
    }

    func url(for query: String) -> URL? {
        let base: String
        switch self {
        case .duckDuckGo: base = "https://duckduckgo.com/"
        case .startpage: base = "https://www.startpage.com/do/search"
        case .brave: base = "https://search.brave.com/search"
        case .google: base = "https://www.google.com/search"
        }
        var c = URLComponents(string: base)
        c?.queryItems = [URLQueryItem(name: "q", value: query)]
        return c?.url
    }
}

/// Shields' settings and the sites he's turned them off for. The switches live in UserDefaults;
/// the site list says where he browses, so it lives in this iPhone's Keychain (never synced).
@MainActor
final class VaultShields: ObservableObject {
    static let shared = VaultShields()

    @Published var settings: VaultShieldSettings {
        didSet { if settings != oldValue { saveSettings() } }
    }
    @Published private(set) var sitesOff: Set<String>

    private static let settingsKey = "vault.shields.settings"
    private static let service = "com.jarviscopilot.vault.shields"
    private static let account = "sites-off"
    private let defaults: UserDefaults
    private let keepsSites: Bool

    init(defaults: UserDefaults = .standard, keepsSites: Bool = true) {
        self.defaults = defaults
        self.keepsSites = keepsSites
        settings = defaults.data(forKey: Self.settingsKey)
            .flatMap { try? JSONDecoder().decode(VaultShieldSettings.self, from: $0) } ?? VaultShieldSettings()
        sitesOff = keepsSites ? Self.readSites() : []
    }

    /// Shields up for this page?
    func isOn(for url: URL?) -> Bool {
        settings.enabled && !sitesOff.contains(VaultShields.site(url))
    }

    func setShields(_ on: Bool, for url: URL?) {
        let site = VaultShields.site(url)
        guard !site.isEmpty else { return }
        if on { sitesOff.remove(site) } else { sitesOff.insert(site) }
        if keepsSites { Self.writeSites(sitesOff) }
    }

    /// The last two labels of a host ("m.example.com" → "example.com").
    nonisolated static func site(_ url: URL?) -> String {
        let labels = (url?.host ?? "").lowercased().split(separator: ".")
        return labels.suffix(2).joined(separator: ".")
    }

    private func saveSettings() {
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: Self.settingsKey) }
    }

    // MARK: Keychain (this device only)

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private static func readSites() -> Set<String> {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data,
              let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(list)
    }

    private static func writeSites(_ sites: Set<String>) {
        guard let data = try? JSONEncoder().encode(sites.sorted()) else { return }
        if SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}

// MARK: - Page scripts

enum VaultShieldScripts {
    static func globalPrivacyControl() -> WKUserScript {
        WKUserScript(source: """
            try { Object.defineProperty(Navigator.prototype, 'globalPrivacyControl', { get: () => true }); } catch (e) {}
            """, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }

    /// Stealth: pages can't tell Shields are on.
    /// - Ad scripts the blocker would stop "load" (an inert script, with stand-ins for
    ///   adsbygoogle / googletag / analytics), so their onload fires and the globals exist.
    /// - Ad pixels and frames load a blank instead of failing; fetch / XHR / beacons to ad hosts
    ///   answer 200 without leaving the phone.
    /// - Bait boxes (class "adsbox", "pub_300x250"…) that ad hiding collapsed report a size, a
    ///   parent and a visible computed style.
    /// - Every patched function still prints as native code.
    static func stealth() -> WKUserScript {
        WKUserScript(source: stealthSource, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }

    static let stealthSource = #"""
    (() => {
      if (window.__jcShieldsPatched) return;
      Object.defineProperty(window, '__jcShieldsPatched', { value: true, enumerable: false });
      const AD_HOST = /(^|\.)(doubleclick\.net|googlesyndication\.com|googleadservices\.com|adservice\.google\.[a-z.]+|google-analytics\.com|googletagmanager\.com|googletagservices\.com|amazon-adsystem\.com|adnxs\.com|taboola\.com|outbrain\.com|criteo\.(com|net)|pubmatic\.com|rubiconproject\.com|openx\.net|adsrvr\.org|moatads\.com|scorecardresearch\.com|exoclick\.com|exosrv\.com|juicyads\.com|trafficjunky\.(com|net)|trafficstars\.com|tsyndicate\.com|popads\.net|popcash\.net|propellerads\.com|adsterra\.com|hilltopads\.net|media\.net|yieldmo\.com|33across\.com|sharethrough\.com|teads\.tv|smartadserver\.com|adform\.net|casalemedia\.com|indexww\.com|bidswitch\.net|quantserve\.com|zedo\.com|adzerk\.net|carbonads\.(com|net)|buysellads\.com|ads-twitter\.com|ads\.linkedin\.com|adcolony\.com|applovin\.com|mgid\.com|revcontent\.com|zergnet\.com|adskeeper\.(com|co\.uk)|realsrv\.com|magsrv\.com)$/i;
      const PIXEL = 'data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==';
      const nativeText = new WeakMap();
      const fnToString = Function.prototype.toString;
      const asNative = (fn, name) => { nativeText.set(fn, 'function ' + name + '() { [native code] }'); return fn; };
      Function.prototype.toString = asNative(function toString() {
        return nativeText.has(this) ? nativeText.get(this) : fnToString.call(this);
      }, 'toString');

      const isAd = (u) => { try { return AD_HOST.test(new URL(String(u), location.href).hostname); } catch (e) { return false; } };
      const surrogate = (u) => {
        let h = '';
        try { const x = new URL(String(u), location.href); h = x.hostname + x.pathname; } catch (e) {}
        let code = '';
        if (/googlesyndication|adsbygoogle/.test(h)) {
          code = 'window.adsbygoogle=window.adsbygoogle||[];window.adsbygoogle.loaded=true;window.adsbygoogle.push=function(){return 0};';
        } else if (/googletagservices|gpt\.js|securepubads/.test(h)) {
          code = '(function(){var g=window.googletag=window.googletag||{};var s={};["addService","setTargeting","defineSizeMapping","setCollapseEmptyDiv","clearTargeting","setClickUrl","setForceSafeFrame","setSafeFrameConfig","updateTargetingFromMap"].forEach(function(k){s[k]=function(){return s}});s.getSlotElementId=function(){return""};s.getAdUnitPath=function(){return""};s.getTargeting=function(){return[]};s.getTargetingKeys=function(){return[]};var p={};["addEventListener","removeEventListener","enableSingleRequest","setTargeting","clearTargeting","collapseEmptyDivs","setPrivacySettings","setRequestNonPersonalizedAds","set","setCentering","updateCorrelator","disableInitialLoad","enableLazyLoad","refresh","clear"].forEach(function(k){p[k]=function(){return p}});p.getSlots=function(){return[]};p.get=function(){return null};p.getTargeting=function(){return[]};g.apiReady=true;g.pubadsReady=true;g.pubads=function(){return p};g.defineSlot=function(){return s};g.defineOutOfPageSlot=function(){return s};g.destroySlots=function(){return true};g.display=function(){};g.enableServices=function(){};g.setAdIframeTitle=function(){};g.companionAds=function(){return{setRefreshUnfilledSlots:function(){}}};g.content=function(){return{setContent:function(){}}};g.sizeMapping=function(){var b={addSize:function(){return b},build:function(){return[]}};return b};var q=Array.isArray(g.cmd)?g.cmd:[];g.cmd={push:function(f){try{f()}catch(e){}return 1}};q.forEach(function(f){try{f()}catch(e){}})})();';
        } else if (/google-analytics|analytics\.js|\/ga\.js/.test(h)) {
          code = '(function(){var ga=function(){var a=arguments[arguments.length-1];if(a&&typeof a==="object"&&typeof a.hitCallback==="function"){try{a.hitCallback()}catch(e){}}};ga.create=function(){return{get:function(){},set:function(){},send:function(){}}};ga.getByName=function(){return null};ga.getAll=function(){return[]};ga.loaded=true;var old=window.ga;window.ga=ga;if(old&&old.q){old.q.forEach(function(x){ga.apply(null,x)})}window._gaq=window._gaq||{push:function(){}};})();';
        }
        return 'data:text/javascript;charset=utf-8,' + encodeURIComponent(code + '/**/');
      };
      const swap = (el, url) => {
        if (el instanceof HTMLScriptElement) return surrogate(url);
        if (el instanceof HTMLImageElement) return PIXEL;
        if (el instanceof HTMLIFrameElement) return 'about:blank';
        return null;
      };
      const original = new WeakMap();
      for (const proto of [HTMLScriptElement.prototype, HTMLImageElement.prototype, HTMLIFrameElement.prototype]) {
        const d = Object.getOwnPropertyDescriptor(proto, 'src');
        if (!d || !d.set) continue;
        Object.defineProperty(proto, 'src', {
          configurable: true, enumerable: d.enumerable,
          get: asNative(function src() { return original.has(this) ? original.get(this) : d.get.call(this); }, 'get src'),
          set: asNative(function src(v) {
            const r = isAd(v) ? swap(this, v) : null;
            if (r) { original.set(this, String(v)); d.set.call(this, r); } else { d.set.call(this, v); }
          }, 'set src'),
        });
      }
      const setAttr = Element.prototype.setAttribute;
      Element.prototype.setAttribute = asNative(function setAttribute(name, value) {
        if (String(name).toLowerCase() === 'src' && isAd(value)) {
          const r = swap(this, value);
          if (r) { original.set(this, String(value)); return setAttr.call(this, name, r); }
        }
        return setAttr.call(this, name, value);
      }, 'setAttribute');
      const getAttr = Element.prototype.getAttribute;
      Element.prototype.getAttribute = asNative(function getAttribute(name) {
        if (String(name).toLowerCase() === 'src' && original.has(this)) return original.get(this);
        return getAttr.call(this, name);
      }, 'getAttribute');

      if (window.fetch) {
        const f = window.fetch;
        window.fetch = asNative(function fetch(input, init) {
          const u = (input && typeof input === 'object' && 'url' in input) ? input.url : input;
          if (isAd(u)) return f.call(this, 'data:text/plain,');
          return f.call(this, input, init);
        }, 'fetch');
      }
      const xopen = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = asNative(function open(method, url, ...rest) {
        if (isAd(url)) return xopen.call(this, 'GET', 'data:text/plain,', ...rest);
        return xopen.call(this, method, url, ...rest);
      }, 'open');
      if (navigator.sendBeacon) {
        const b = navigator.sendBeacon;
        navigator.sendBeacon = asNative(function sendBeacon(url, data) {
          return isAd(url) ? true : b.call(navigator, url, data);
        }, 'sendBeacon');
      }

      // Bait boxes collapsed by ad hiding still look laid out.
      const BAIT = /(^|[\s_-])(ad|ads|adv|advert|advertisement|advertising|adsbox|adsbygoogle|adbanner|adbox|adslot|adunit|adzone|adplacement|banner_?ads?|textads?|text_?ads?|text-ad-links|sponsor|sponsored|pub_\d+x\d+m?|ad-(banner|box|slot|unit|zone|placement|container|wrapper|frame|space|block)|doubleclick)([\s_-]|$)/i;
      const gcs = window.getComputedStyle;
      const looksBait = (el) => {
        if (!el || el.nodeType !== 1) return false;
        const cls = typeof el.className === 'string' ? el.className : (getAttr.call(el, 'class') || '');
        return BAIT.test((el.id || '') + ' ' + cls);
      };
      const collapsed = (el) => { try { return looksBait(el) && gcs.call(window, el).display === 'none'; } catch (e) { return false; } };
      const px = (el, prop, dflt) => { const v = parseFloat((el.style && el.style[prop]) || ''); return v > 0 ? v : dflt; };
      const fakes = {
        offsetHeight: (el) => px(el, 'height', 1), offsetWidth: (el) => px(el, 'width', 1),
        clientHeight: (el) => px(el, 'height', 1), clientWidth: (el) => px(el, 'width', 1),
        offsetTop: () => 1, offsetLeft: () => 1, offsetParent: () => document.body,
      };
      for (const [prop, fake] of Object.entries(fakes)) {
        for (const proto of [HTMLElement.prototype, Element.prototype]) {
          const d = Object.getOwnPropertyDescriptor(proto, prop);
          if (!d || !d.get) continue;
          Object.defineProperty(proto, prop, {
            configurable: true, enumerable: d.enumerable,
            get: asNative(function () {
              const real = d.get.call(this);
              return (real === 0 || real === null) && collapsed(this) ? fake(this) : real;
            }, 'get ' + prop),
          });
        }
      }
      const rect = Element.prototype.getBoundingClientRect;
      Element.prototype.getBoundingClientRect = asNative(function getBoundingClientRect() {
        const r = rect.call(this);
        if (r.width === 0 && r.height === 0 && collapsed(this)) {
          return new DOMRect(1, 1, px(this, 'width', 1), px(this, 'height', 1));
        }
        return r;
      }, 'getBoundingClientRect');
      window.getComputedStyle = asNative(function getComputedStyle(el, pseudo) {
        const style = gcs.call(window, el, pseudo);
        if (!collapsed(el)) return style;
        const fix = (name, v) => name === 'display' ? 'block' : name === 'visibility' ? 'visible' : v;
        return new Proxy(style, {
          get(target, prop) {
            if (prop === 'display' || prop === 'visibility') return fix(prop, target[prop]);
            if (prop === 'getPropertyValue') return (n) => fix(n, target.getPropertyValue(n));
            const v = target[prop];
            return typeof v === 'function' ? v.bind(target) : v;
          },
        });
      }, 'getComputedStyle');
    })();
    """#
}

// MARK: - The settings sheet

/// The shield button's sheet: Shields for this site, then every switch.
struct VaultShieldsSheet: View {
    @ObservedObject var shields: VaultShields
    let url: URL?
    let blockedPopups: Int
    @Environment(\.dismiss) private var dismiss

    private var site: String { VaultShields.site(url) }

    var body: some View {
        NavigationStack {
            ScrollView {
                JcPageColumn {
                    siteCard
                    JcSectionLabel("Jarvis Shields")
                    JcCard(padding: 0) {
                        toggle("shield.fill", "Jarvis Shields", "Every protection below, on every site.",
                               $shields.settings.enabled)
                        toggle("hand.raised", "Block ads and trackers",
                               "About 92,000 ad and tracking servers, from EasyList and EasyPrivacy.",
                               $shields.settings.blockAds)
                            .disabled(!shields.settings.enabled)
                        toggle("eye.slash", "Hide empty ad spaces", "Collapses the boxes blocked ads leave behind.",
                               $shields.settings.hideAdSpaces)
                            .disabled(!shields.settings.enabled)
                        toggle("rectangle.on.rectangle.slash", "Block pop-ups",
                               "Pop-ups to other sites wait for a tap.", $shields.settings.blockPopups, last: true)
                            .disabled(!shields.settings.enabled)
                    }
                    JcSectionLabel("Stealth")
                    JcCard(padding: 0) {
                        toggle("theatermasks", "Hide Shields from sites",
                               "Blocked ads look loaded to the page, so “turn off your ad blocker” walls don’t appear.",
                               $shields.settings.stealth, last: true)
                            .disabled(!shields.settings.enabled || !shields.settings.blockAds)
                    }
                    JcSectionLabel("Privacy")
                    JcCard(padding: 0) {
                        toggle("hand.raised.slash", "Global Privacy Control",
                               "Tells every site not to sell or share your data.",
                               $shields.settings.globalPrivacyControl)
                        toggle("curlybraces", "JavaScript", "Off makes most sites simpler; some stop working.",
                               $shields.settings.javascript)
                        toggle("play.slash", "Block autoplay", "Applies the next time the browser opens.",
                               $shields.settings.blockAutoplay, last: true)
                    }
                    JcSectionLabel("Search with")
                    JcCard(padding: 0) {
                        ForEach(Array(VaultSearchEngine.allCases.enumerated()), id: \.element) { i, engine in
                            JcRow(title: engine.name, last: i == VaultSearchEngine.allCases.count - 1,
                                  action: { shields.settings.search = engine }) {
                                if shields.settings.search == engine {
                                    JcIcon("checkmark", size: 14, weight: .semibold).foregroundStyle(JcTheme.text)
                                }
                            }
                        }
                    }
                    Text("Nothing you browse is kept after the browser closes. Changes reload the page.")
                        .font(.system(size: 12))
                        .foregroundStyle(JcTheme.muted)
                        .padding(.top, 12)
                        .padding(.bottom, 24)
                }
            }
            .background(JcTheme.bg.ignoresSafeArea())
            .navigationTitle("Shields")
            .navigationBarTitleDisplayMode(.inline)
            .toggleStyle(.jcSwitch)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.foregroundStyle(JcTheme.text)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    /// This site: one big switch, and what's been held back here.
    private var siteCard: some View {
        let on = shields.isOn(for: url)
        let status: String
        if !shields.settings.enabled {
            status = "Shields are off everywhere"
        } else if !on {
            status = "Shields down for this site"
        } else if blockedPopups > 0 {
            status = "Shields up · \(blockedPopups) pop-up\(blockedPopups == 1 ? "" : "s") blocked"
        } else {
            status = "Shields up"
        }
        return JcCard {
            HStack(spacing: 14) {
                JcIcon(on ? "shield.fill" : "shield.slash", size: 24)
                    .foregroundStyle(on ? JcTheme.text : JcTheme.muted)
                    .frame(width: 44, height: 44)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(site.isEmpty ? "This page" : site)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(JcTheme.text)
                        .lineLimit(1)
                    Text(status)
                        .font(.system(size: 13))
                        .foregroundStyle(JcTheme.muted)
                }
                Spacer(minLength: 8)
                Toggle("Shields for this site", isOn: Binding(
                    get: { shields.isOn(for: url) },
                    set: { shields.setShields($0, for: url) }))
                    .labelsHidden()
                    .disabled(!shields.settings.enabled || site.isEmpty)
            }
        }
        .padding(.top, 8)
    }

    private func toggle(_ symbol: String, _ title: String, _ subtitle: String, _ isOn: Binding<Bool>,
                        last: Bool = false) -> some View {
        JcRow(symbol: symbol, title: title, subtitle: subtitle, subtitleLines: 3, last: last) {
            Toggle(title, isOn: isOn).labelsHidden()
        }
    }
}
