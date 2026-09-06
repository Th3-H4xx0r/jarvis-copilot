#include "WifiLink.h"

#include <ESPmDNS.h>
#include <Preferences.h>

#include "Config.h"

namespace jarvis {

namespace {
constexpr const char* prefs_namespace = "jarvis";
constexpr const char* key_ssid = "ssid";
constexpr const char* key_password = "pass";

constexpr uint32_t join_timeout_ms = 20000;
constexpr uint32_t retry_interval_ms = 30000;
// A client that connects and never authenticates is dropped after this long.
constexpr uint32_t auth_grace_ms = 5000;
// Any idle client is dropped so a phone that vanished doesn't hold the single slot.
constexpr uint32_t client_idle_ms = 120000;
// Scan results older than this are thrown away when the app asks for page 0 again.
constexpr uint32_t scan_cache_ms = 30000;
}  // namespace

void WifiLink::begin(const String& hostname, FrameHandler on_frame) {
  hostname_ = hostname;
  on_frame_ = std::move(on_frame);
  load_credentials();
  if (has_credentials()) {
    start_join(millis());
  } else {
    set_state(proto::WifiState::off);
  }
}

void WifiLink::ensure_stack() {
  if (stack_started_) return;
  WiFi.persistent(false);  // we keep credentials ourselves, not in the SDK's NVS blob
  WiFi.mode(WIFI_STA);
  WiFi.setHostname(hostname_.c_str());
  WiFi.setAutoReconnect(true);
  // BLE and Wi‑Fi share the radio; modem sleep is what lets them coexist cleanly.
  WiFi.setSleep(true);
  stack_started_ = true;
  Serial.printf("[wifi] stack up, free heap %u bytes\n", ESP.getFreeHeap());
}

void WifiLink::load_credentials() {
  Preferences prefs;
  if (!prefs.begin(prefs_namespace, /*readOnly=*/true)) return;
  ssid_ = prefs.getString(key_ssid, "");
  password_ = prefs.getString(key_password, "");
  prefs.end();
}

bool WifiLink::set_credentials(const String& ssid, const String& password) {
  if (ssid.isEmpty() || ssid.length() > proto::max_ssid_len || password.length() > proto::max_password_len) {
    return false;
  }
  Preferences prefs;
  if (!prefs.begin(prefs_namespace, /*readOnly=*/false)) return false;
  prefs.putString(key_ssid, ssid);
  prefs.putString(key_password, password);
  prefs.end();

  ssid_ = ssid;
  password_ = password;
  drop_client();
  if (stack_started_) WiFi.disconnect(false, true);
  start_join(millis());
  return true;
}

void WifiLink::forget() {
  Preferences prefs;
  if (prefs.begin(prefs_namespace, /*readOnly=*/false)) {
    prefs.remove(key_ssid);
    prefs.remove(key_password);
    prefs.end();
  }
  ssid_ = "";
  password_ = "";
  drop_client();
  if (mdns_started_) { MDNS.end(); mdns_started_ = false; }
  if (server_started_) { server_.end(); server_started_ = false; }
  if (stack_started_) {
    WiFi.disconnect(false, true);
    WiFi.mode(WIFI_OFF);  // tears the driver down and returns its RAM
    stack_started_ = false;
  }
  set_state(proto::WifiState::off);
}

void WifiLink::start_join(uint32_t now) {
  ensure_stack();
  Serial.printf("[wifi] joining '%s'\n", ssid_.c_str());
  WiFi.begin(ssid_.c_str(), password_.c_str());
  join_started_ms_ = now;
  set_state(proto::WifiState::connecting);
}

void WifiLink::set_state(proto::WifiState s) {
  if (s == state_) return;
  state_ = s;
  state_changed_ = true;
}

void WifiLink::on_connected() {
  Serial.printf("[wifi] connected, ip %s rssi %d\n", WiFi.localIP().toString().c_str(), WiFi.RSSI());
  if (!server_started_) {
    server_.begin();
    server_.setNoDelay(true);
    server_started_ = true;
  }
  if (!mdns_started_ && MDNS.begin(hostname_.c_str())) {
    MDNS.addService(proto::mdns_service, "tcp", proto::tcp_port);
    mdns_started_ = true;
  }
  set_state(proto::WifiState::connected);
}

void WifiLink::service(uint32_t now) {
  if (!has_credentials()) return;

  const wl_status_t wl = WiFi.status();
  switch (state_) {
    case proto::WifiState::connecting:
      if (wl == WL_CONNECTED) {
        on_connected();
      } else if (now - join_started_ms_ > join_timeout_ms) {
        Serial.println("[wifi] join timed out");
        WiFi.disconnect(false, false);
        next_retry_ms_ = now + retry_interval_ms;
        set_state(proto::WifiState::failed);
      }
      break;
    case proto::WifiState::connected:
      if (wl != WL_CONNECTED) {
        Serial.println("[wifi] link lost");
        drop_client();
        // Auto-reconnect is on; treat it as a fresh join so the timeout applies.
        join_started_ms_ = now;
        set_state(proto::WifiState::connecting);
      }
      break;
    case proto::WifiState::failed:
      if (static_cast<int32_t>(now - next_retry_ms_) >= 0) start_join(now);
      break;
    case proto::WifiState::off:
      start_join(now);
      break;
  }

  if (state_ == proto::WifiState::connected) service_client(now);
}

void WifiLink::service_client(uint32_t now) {
  if (server_.hasClient()) {
    // One phone at a time. A new connection replaces a stale one rather than being
    // refused, so a phone that lost its socket can always get back in.
    WiFiClient incoming = server_.accept();
    if (client_connected()) {
      Serial.println("[tcp] replacing existing client");
      client_.stop();
    }
    client_ = incoming;
    client_.setNoDelay(true);
    client_authenticated_ = false;
    client_connected_ms_ = now;
    client_last_rx_ms_ = now;
    parser_.reset();
    Serial.printf("[tcp] client %s connected\n", client_.remoteIP().toString().c_str());
  }

  if (!client_connected()) return;

  if (!client_authenticated_ && now - client_connected_ms_ > auth_grace_ms) {
    Serial.println("[tcp] client never authenticated, dropping");
    drop_client();
    return;
  }
  if (now - client_last_rx_ms_ > client_idle_ms) {
    Serial.println("[tcp] client idle, dropping");
    drop_client();
    return;
  }

  // Bounded per call so one chatty client can't starve the GPIO loop.
  int budget = 512;
  while (budget-- > 0 && client_.available() > 0) {
    const int b = client_.read();
    if (b < 0) break;
    client_last_rx_ms_ = now;
    if (parser_.feed(static_cast<uint8_t>(b)) && on_frame_) {
      on_frame_(parser_.frame(), parser_.frame_len());
      if (!client_connected()) return;  // handler may have dropped us
    }
  }
}

proto::Status WifiLink::scan_page(uint8_t page, proto::FrameBuilder& fb, uint32_t now) {
  ensure_stack();
  int16_t found = WiFi.scanComplete();
  if (found == WIFI_SCAN_RUNNING) return proto::Status::scanning;
  const bool stale = now - scan_started_ms_ > scan_cache_ms;
  if (found < 0 || (page == 0 && (stale || !scan_running_))) {
    // scanNetworks(async) works whether or not we're joined to an AP. Results come
    // back sorted strongest-first.
    WiFi.scanDelete();
    WiFi.scanNetworks(/*async=*/true, /*show_hidden=*/false);
    scan_started_ms_ = now;
    scan_running_ = true;
    return proto::Status::scanning;
  }
  const size_t total = static_cast<size_t>(found);
  const size_t start = static_cast<size_t>(page) * proto::scan_page_size;
  fb.push(static_cast<uint8_t>(total > 255 ? 255 : total));
  fb.push(page);
  const size_t end = start + proto::scan_page_size < total ? start + proto::scan_page_size : total;
  fb.push(static_cast<uint8_t>(end > start ? end - start : 0));
  for (size_t i = start; i < end; ++i) {
    fb.push(static_cast<uint8_t>(static_cast<int8_t>(WiFi.RSSI(i))));
    fb.push(WiFi.encryptionType(i) == WIFI_AUTH_OPEN ? 0 : 1);
    fb.push_string(WiFi.SSID(i).c_str(), proto::max_ssid_len);
  }
  if (end >= total) scan_running_ = false;  // last page served; page 0 next time rescans
  return proto::Status::ok;
}

void WifiLink::send(const uint8_t* frame, size_t len) {
  if (!client_connected()) return;
  client_.write(frame, len);
}

void WifiLink::drop_client() {
  if (client_) client_.stop();
  client_authenticated_ = false;
  parser_.reset();
}

}  // namespace jarvis
