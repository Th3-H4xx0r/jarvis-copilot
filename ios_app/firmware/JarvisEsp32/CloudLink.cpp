#include "CloudLink.h"

#include <WiFi.h>
#include <Preferences.h>
#include <esp_random.h>
#include <mbedtls/base64.h>

#include "Config.h"

namespace cfg = jarvis::config;

namespace jarvis {

namespace {
constexpr const char* prefs_namespace = "jarvis";
constexpr const char* key_server = "srv";
constexpr const char* key_cookie = "cookie";
constexpr const char* key_cf_id = "cfid";
constexpr const char* key_cf_secret = "cfsec";
constexpr const char* key_mode = "cloud";
constexpr const char* key_bg_session = "bgsess";
constexpr const char* key_last_error = "clouderr";
constexpr const char* key_fallback = "cloudfb";
constexpr const char* key_pend_url = "pendurl";
constexpr const char* key_pend_code = "pendcode";
constexpr const char* key_pend_cfid = "pendcfid";
constexpr const char* key_pend_cfsec = "pendcfsec";

constexpr const char* user_agent = "JarvisEsp32/1.0";
constexpr const char* bridge_path = "/api/devices/bridge/ws";
constexpr uint32_t http_timeout_ms = 12000;
constexpr uint32_t ws_ping_interval_ms = 30000;
constexpr uint32_t ws_dead_after_ms = 75000;      // server pings every ~18 s
constexpr uint32_t backoff_max_ms = 60000;
constexpr uint32_t fallback_after_ms = 5 * 60 * 1000;  // no link this long → back to BLE
constexpr size_t rx_max = 24 * 1024;              // upload_script sources are ≤ 16 KB

// Reads the HTTP status line, waiting for the first bytes and skipping any blank
// lines ahead of it. Returns 0 when nothing usable arrives in time.
int read_status_line(NetworkClientSecure& client, uint32_t timeout_ms) {
  const uint32_t start = millis();
  while (millis() - start < timeout_ms) {
    if (!client.available()) {
      if (!client.connected()) return 0;
      delay(5);
      continue;
    }
    String line = client.readStringUntil('\n');
    line.trim();
    if (line.isEmpty()) continue;
    const int at = line.indexOf("HTTP/");
    if (at < 0) return 0;
    const int sp = line.indexOf(' ', at);
    return sp > 0 ? line.substring(sp + 1, sp + 4).toInt() : 0;
  }
  return 0;
}

String base64(const uint8_t* data, size_t len) {
  size_t out_len = 0;
  mbedtls_base64_encode(nullptr, 0, &out_len, data, len);
  std::unique_ptr<unsigned char[]> buf(new unsigned char[out_len + 1]);
  mbedtls_base64_encode(buf.get(), out_len + 1, &out_len, data, len);
  return String(reinterpret_cast<char*>(buf.get()), out_len);
}
}  // namespace

// ───────────────────────────── Storage ─────────────────────────────

void CloudLink::begin(const char* skills_json, SkillRunner run) {
  skills_json_ = skills_json;
  run_ = std::move(run);
  load();
  state_ = paired() ? (mode_ ? proto::CloudState::connecting : proto::CloudState::paired)
                    : (last_error_.length() ? proto::CloudState::failed : proto::CloudState::off);
  Serial.printf("[cloud] %s%s\n", paired() ? "paired with " : "not paired", paired() ? server_.c_str() : "");
}

void CloudLink::load() {
  Preferences prefs;
  if (!prefs.begin(prefs_namespace, /*readOnly=*/true)) return;
  server_ = prefs.getString(key_server, "");
  cookie_ = prefs.getString(key_cookie, "");
  cf_id_ = prefs.getString(key_cf_id, "");
  cf_secret_ = prefs.getString(key_cf_secret, "");
  bg_session_ = prefs.getString(key_bg_session, "");
  last_error_ = prefs.getString(key_last_error, "");
  mode_ = prefs.getBool(key_mode, false) && paired();
  from_fallback_ = prefs.getBool(key_fallback, false);
  if (from_fallback_) { prefs.end(); Preferences w; if (w.begin(prefs_namespace, false)) { w.remove(key_fallback); w.end(); } prefs.begin(prefs_namespace, true); }
  pending_url_ = prefs.getString(key_pend_url, "");
  pending_code_ = prefs.getString(key_pend_code, "");
  pending_cf_id_ = prefs.getString(key_pend_cfid, "");
  pending_cf_secret_ = prefs.getString(key_pend_cfsec, "");
  prefs.end();
}

void CloudLink::stage_pairing(const String& url, const String& code, const String& cf_id, const String& cf_secret) {
  Preferences prefs;
  if (!prefs.begin(prefs_namespace, /*readOnly=*/false)) return;
  prefs.putString(key_pend_url, url);
  prefs.putString(key_pend_code, code);
  prefs.putString(key_pend_cfid, cf_id);
  prefs.putString(key_pend_cfsec, cf_secret);
  prefs.putString(key_last_error, "");
  prefs.end();
  pending_url_ = url; pending_code_ = code; pending_cf_id_ = cf_id; pending_cf_secret_ = cf_secret;
  last_error_ = "";
  set_state(proto::CloudState::connecting);
}

void CloudLink::clear_pending_pairing() {
  Preferences prefs;
  if (prefs.begin(prefs_namespace, /*readOnly=*/false)) {
    prefs.remove(key_pend_url); prefs.remove(key_pend_code);
    prefs.remove(key_pend_cfid); prefs.remove(key_pend_cfsec);
    prefs.end();
  }
  pending_url_ = ""; pending_code_ = ""; pending_cf_id_ = ""; pending_cf_secret_ = "";
}

bool CloudLink::run_pending_pairing(String& error) {
  if (!has_pending_pairing()) { error = "nothing staged"; return false; }
  const bool ok = pair(pending_url_, pending_code_, pending_cf_id_, pending_cf_secret_, error);
  clear_pending_pairing();
  return ok;
}

void CloudLink::save() {
  Preferences prefs;
  if (!prefs.begin(prefs_namespace, /*readOnly=*/false)) return;
  prefs.putString(key_server, server_);
  prefs.putString(key_cookie, cookie_);
  prefs.putString(key_cf_id, cf_id_);
  prefs.putString(key_cf_secret, cf_secret_);
  prefs.putString(key_bg_session, bg_session_);
  prefs.putString(key_last_error, last_error_);
  prefs.putBool(key_mode, mode_);
  prefs.end();
}

void CloudLink::set_state(proto::CloudState s, const String& error) {
  last_error_ = error;
  if (s == state_) return;
  state_ = s;
  state_changed_ = true;
}

bool CloudLink::parse_server(String& host, uint16_t& port, String& base) const {
  String s = server_;
  if (s.startsWith("https://")) s = s.substring(8);
  else if (s.startsWith("http://")) s = s.substring(7);
  const int slash = s.indexOf('/');
  String hp = slash >= 0 ? s.substring(0, slash) : s;
  base = slash >= 0 ? s.substring(slash) : "";
  while (base.endsWith("/")) base.remove(base.length() - 1);
  const int colon = hp.indexOf(':');
  host = colon >= 0 ? hp.substring(0, colon) : hp;
  port = colon >= 0 ? static_cast<uint16_t>(hp.substring(colon + 1).toInt()) : 443;
  return host.length() > 0;
}

// ───────────────────────────── HTTPS ─────────────────────────────

bool CloudLink::http_post(const String& path, const String& json, HttpResponse& out, bool with_session) {
  String host, base;
  uint16_t port;
  if (!parse_server(host, port, base)) { out.status = 0; return false; }

  IPAddress resolved;
  if (!WiFi.hostByName(host.c_str(), resolved)) {
    out.status = 0;
    out.body = "dns lookup failed for " + host;
    Serial.printf("[cloud] %s\n", out.body.c_str());
    return false;
  }
  NetworkClientSecure client;
  // The Cloudflare edge certificate chain would need the full CA bundle in flash;
  // the session cookie and CF service token are the real gate, so skip chain
  // validation here. (Same trade-off the loopback tools make.)
  client.setInsecure();
  client.setHandshakeTimeout(20);
  client.setTimeout(http_timeout_ms / 1000);
  Serial.printf("[cloud] tls connect %s (%s):%u, free %u / largest block %u\n", host.c_str(),
                resolved.toString().c_str(), port, ESP.getFreeHeap(), ESP.getMaxAllocHeap());
  if (!client.connect(host.c_str(), port, static_cast<int32_t>(http_timeout_ms))) {
    char buf[120] = {0};
    const int code = client.lastError(buf, sizeof(buf));
    out.status = 0;
    out.body = String("tls connect failed: ") + (buf[0] ? buf : "unknown") + " (" + String(code) + ")";
    Serial.printf("[cloud] %s\n", out.body.c_str());
    return false;
  }
  String req;
  req.reserve(400 + json.length());
  req += "POST " + base + path + " HTTP/1.1\r\n";
  req += "Host: " + host + "\r\n";
  req += "User-Agent: " + String(user_agent) + "\r\n";
  req += "Accept: application/json\r\n";
  req += "Content-Type: application/json\r\n";
  req += "Connection: close\r\n";
  if (cf_id_.length()) {
    req += "CF-Access-Client-Id: " + cf_id_ + "\r\n";
    req += "CF-Access-Client-Secret: " + cf_secret_ + "\r\n";
  }
  if (with_session && cookie_.length()) req += "Cookie: hermes_session=" + cookie_ + "\r\n";
  req += "Content-Length: " + String(json.length()) + "\r\n\r\n";
  req += json;
  client.print(req);

  out.status = read_status_line(client, http_timeout_ms);
  if (out.status == 0) {
    out.body = "no HTTP response from server";
    client.stop();
    return false;
  }
  // Headers.
  String line;
  long content_length = -1;
  bool chunked = false;
  while (client.connected() || client.available()) {
    line = client.readStringUntil('\n');
    line.trim();
    if (line.isEmpty()) break;
    String lower = line; lower.toLowerCase();
    if (lower.startsWith("content-length:")) content_length = line.substring(15).toInt();
    else if (lower.startsWith("transfer-encoding:") && lower.indexOf("chunked") >= 0) chunked = true;
    else if (lower.startsWith("set-cookie:")) {
      const int at = lower.indexOf("hermes_session=");
      if (at >= 0) {
        String v = line.substring(at + 15);
        const int semi = v.indexOf(';');
        out.set_cookie = semi >= 0 ? v.substring(0, semi) : v;
        out.set_cookie.trim();
      }
    }
  }
  // Body.
  out.body = "";
  const uint32_t start = millis();
  if (chunked) {
    while (millis() - start < http_timeout_ms) {
      line = client.readStringUntil('\n'); line.trim();
      const long n = strtol(line.c_str(), nullptr, 16);
      if (n <= 0) break;
      for (long i = 0; i < n; ++i) {
        while (!client.available() && client.connected() && millis() - start < http_timeout_ms) delay(1);
        const int c = client.read();
        if (c < 0) break;
        out.body += static_cast<char>(c);
      }
      client.readStringUntil('\n');
    }
  } else {
    while ((client.connected() || client.available()) && millis() - start < http_timeout_ms) {
      if (client.available()) {
        out.body += static_cast<char>(client.read());
        if (content_length >= 0 && static_cast<long>(out.body.length()) >= content_length) break;
      } else {
        delay(1);
      }
    }
  }
  client.stop();
  return out.status > 0;
}

// ───────────────────────────── Pairing ─────────────────────────────

bool CloudLink::pair(const String& url, const String& code, const String& cf_id, const String& cf_secret, String& error) {
  String trimmed = url; trimmed.trim();
  while (trimmed.endsWith("/")) trimmed.remove(trimmed.length() - 1);
  if (trimmed.isEmpty()) { error = "server url missing"; return false; }
  if (!trimmed.startsWith("http")) trimmed = "https://" + trimmed;
  server_ = trimmed;
  cf_id_ = cf_id;
  cf_secret_ = cf_secret;
  cookie_ = "";

  JsonDocument doc;
  doc["code"] = code;
  doc["name"] = String(cfg::device_name_prefix) + " board";
  String body;
  serializeJson(doc, body);
  HttpResponse res;
  if (!http_post("/api/auth/pair/claim", body, res, /*with_session=*/false)) {
    error = "could not reach " + server_ + ": " + (res.body.isEmpty() ? "no response" : res.body);
    last_error_ = error; mode_ = false; save();
    return false;
  }
  if (res.status != 200 || res.set_cookie.isEmpty()) {
    error = "pairing rejected (" + String(res.status) + ")";
    last_error_ = error; mode_ = false; save();
    return false;
  }
  cookie_ = res.set_cookie;
  JsonDocument reply;
  if (deserializeJson(reply, res.body) == DeserializationError::Ok && reply["cf_access"].is<JsonObjectConst>()) {
    cf_id_ = reply["cf_access"]["client_id"].as<String>();
    cf_secret_ = reply["cf_access"]["client_secret"].as<String>();
  }
  mode_ = true;
  bg_session_ = "";
  last_error_ = "";
  save();
  set_state(proto::CloudState::paired);
  Serial.println("[cloud] paired; rebooting into cloud mode");
  reboot_at_ = millis() + 300;
  return true;
}

void CloudLink::arm() {
  if (!paired()) return;
  mode_ = true;
  save();
}

void CloudLink::disarm(bool fallback) {
  ws_close();
  mode_ = false;
  save();
  if (fallback) {
    Preferences prefs;
    if (prefs.begin(prefs_namespace, false)) { prefs.putBool(key_fallback, true); prefs.end(); }
  }
  set_state(paired() ? proto::CloudState::paired : proto::CloudState::off);
}

void CloudLink::forget() {
  ws_close();
  server_ = ""; cookie_ = ""; cf_id_ = ""; cf_secret_ = ""; bg_session_ = "";
  mode_ = false;
  save();
  set_state(proto::CloudState::off);
}

// ───────────────────────────── Service ─────────────────────────────

void CloudLink::service(uint32_t now, bool wifi_connected) {
  if (!mode_ || !paired()) return;

  if (!wifi_connected) {
    if (ws_open_) { ws_close(); set_state(proto::CloudState::connecting, "Wi‑Fi down"); }
    if (offline_since_ms_ == 0) offline_since_ms_ = now;
  } else if (!ws_open_) {
    if (offline_since_ms_ == 0) offline_since_ms_ = now;
    if (static_cast<int32_t>(now - next_connect_ms_) >= 0) {
      if (ws_connect()) {
        offline_since_ms_ = 0;
        backoff_ms_ = 5000;
      } else {
        next_connect_ms_ = now + backoff_ms_;
        backoff_ms_ = backoff_ms_ * 2 > backoff_max_ms ? backoff_max_ms : backoff_ms_ * 2;
      }
    }
  } else {
    offline_since_ms_ = 0;
    ws_poll(now);
  }

  // Nothing for minutes: hand the board back to Bluetooth so the phone can reach it.
  if (offline_since_ms_ != 0 && now - offline_since_ms_ > fallback_after_ms &&
      state_ != proto::CloudState::expired) {
    Serial.println("[cloud] unreachable for too long, rebooting into Bluetooth mode");
    disarm(/*fallback=*/true);
    reboot_at_ = now + 200;
  }
}

// ───────────────────────────── WebSocket ─────────────────────────────

bool CloudLink::ws_connect() {
  String host, base;
  uint16_t port;
  if (!parse_server(host, port, base)) return false;
  set_state(proto::CloudState::connecting);
  Serial.printf("[cloud] connecting to %s\n", host.c_str());

  ws_.reset(new NetworkClientSecure());
  ws_->setInsecure();
  ws_->setTimeout(http_timeout_ms / 1000);
  if (!ws_->connect(host.c_str(), port, static_cast<int32_t>(http_timeout_ms))) {
    ws_.reset();
    set_state(proto::CloudState::failed, "TLS connect failed");
    return false;
  }
  uint8_t nonce[16];
  esp_fill_random(nonce, sizeof(nonce));
  const String key = base64(nonce, sizeof(nonce));
  String req;
  req += "GET " + base + bridge_path + " HTTP/1.1\r\n";
  req += "Host: " + host + "\r\n";
  req += "Upgrade: websocket\r\nConnection: Upgrade\r\n";
  req += "Sec-WebSocket-Key: " + key + "\r\nSec-WebSocket-Version: 13\r\n";
  req += "User-Agent: " + String(user_agent) + "\r\n";
  req += "Cookie: hermes_session=" + cookie_ + "\r\n";
  if (cf_id_.length()) {
    req += "CF-Access-Client-Id: " + cf_id_ + "\r\n";
    req += "CF-Access-Client-Secret: " + cf_secret_ + "\r\n";
  }
  req += "\r\n";
  ws_->print(req);

  const int status = read_status_line(*ws_, http_timeout_ms);
  const bool upgraded = status == 101;
  String line;
  while (ws_->connected() || ws_->available()) {
    line = ws_->readStringUntil('\n');
    line.trim();
    if (line.isEmpty()) break;
  }
  if (!upgraded) {
    ws_->stop();
    ws_.reset();
    if (status == 401 || status == 403) {
      set_state(proto::CloudState::expired, "server rejected the session (" + String(status) + ")");
    } else {
      set_state(proto::CloudState::failed, "upgrade failed (" + String(status) + ")");
    }
    return false;
  }
  ws_open_ = true;
  rx_len_ = 0; rx_need_ = 0; rx_header_done_ = false; hdr_len_ = 0;
  last_rx_ms_ = last_ping_ms_ = millis();
  // The server answers with `hello`; we register right away rather than wait for it.
  ws_send_text(String("{\"type\":\"register\",\"skills\":") + skills_json_ + "}");
  set_state(proto::CloudState::connected);
  Serial.println("[cloud] bridge up, skills registered");
  return true;
}

void CloudLink::ws_close() {
  if (ws_) {
    if (ws_open_) ws_send_frame(0x8, nullptr, 0);
    ws_->stop();
    ws_.reset();
  }
  ws_open_ = false;
  rx_.reset(); rx_cap_ = 0; rx_len_ = 0;
}

void CloudLink::ws_send_frame(uint8_t opcode, const uint8_t* data, size_t len) {
  if (!ws_ || !ws_->connected()) return;
  uint8_t header[14];
  size_t h = 0;
  header[h++] = 0x80 | opcode;
  if (len < 126) {
    header[h++] = 0x80 | static_cast<uint8_t>(len);
  } else if (len < 65536) {
    header[h++] = 0x80 | 126;
    header[h++] = static_cast<uint8_t>(len >> 8);
    header[h++] = static_cast<uint8_t>(len);
  } else {
    header[h++] = 0x80 | 127;
    for (int i = 7; i >= 0; --i) header[h++] = static_cast<uint8_t>((static_cast<uint64_t>(len) >> (8 * i)) & 0xFF);
  }
  uint8_t mask[4];
  esp_fill_random(mask, sizeof(mask));
  memcpy(header + h, mask, 4);
  h += 4;
  ws_->write(header, h);
  // Mask in chunks so a 16 KB skills catalogue doesn't need a second copy.
  uint8_t buf[256];
  for (size_t off = 0; off < len; off += sizeof(buf)) {
    const size_t n = len - off < sizeof(buf) ? len - off : sizeof(buf);
    for (size_t i = 0; i < n; ++i) buf[i] = data[off + i] ^ mask[(off + i) & 3];
    ws_->write(buf, n);
  }
}

bool CloudLink::ws_send_text(const String& text) {
  if (!ws_open_) return false;
  ws_send_frame(0x1, reinterpret_cast<const uint8_t*>(text.c_str()), text.length());
  return true;
}

void CloudLink::ws_poll(uint32_t now) {
  if (!ws_ || !ws_->connected()) {
    Serial.println("[cloud] bridge dropped");
    ws_close();
    set_state(proto::CloudState::connecting, "link dropped");
    next_connect_ms_ = now + 2000;
    return;
  }
  // Bounded per loop so GPIO servicing keeps its cadence.
  int budget = 2048;
  while (budget-- > 0 && ws_->available() > 0) {
    const int b = ws_->read();
    if (b < 0) break;
    last_rx_ms_ = now;
    if (!rx_header_done_) {
      hdr_[hdr_len_++] = static_cast<uint8_t>(b);
      if (hdr_len_ < 2) continue;
      const uint8_t len7 = hdr_[1] & 0x7F;
      const bool masked = hdr_[1] & 0x80;   // servers must not mask; tolerate anyway
      const size_t need_hdr = 2 + (len7 == 126 ? 2 : len7 == 127 ? 8 : 0) + (masked ? 4 : 0);
      if (hdr_len_ < need_hdr) continue;
      size_t plen = len7;
      if (len7 == 126) plen = (static_cast<size_t>(hdr_[2]) << 8) | hdr_[3];
      else if (len7 == 127) { plen = 0; for (int i = 0; i < 8; ++i) plen = (plen << 8) | hdr_[2 + i]; }
      rx_opcode_ = hdr_[0] & 0x0F;
      rx_need_ = plen;
      rx_len_ = 0;
      rx_header_done_ = true;
      hdr_len_ = 0;
      if (plen > rx_max) {
        Serial.printf("[cloud] frame of %u bytes too large, closing\n", static_cast<unsigned>(plen));
        ws_close();
        set_state(proto::CloudState::connecting, "oversized frame");
        return;
      }
      if (plen + 1 > rx_cap_) {
        rx_.reset(new uint8_t[plen + 1]);
        rx_cap_ = plen + 1;
      }
      if (plen == 0) { rx_header_done_ = false; if (rx_opcode_ == 0x9) ws_send_frame(0xA, nullptr, 0); }
      continue;
    }
    rx_[rx_len_++] = static_cast<uint8_t>(b);
    if (rx_len_ < rx_need_) continue;
    rx_header_done_ = false;
    rx_[rx_len_] = 0;
    switch (rx_opcode_) {
      case 0x1: ws_handle_text(reinterpret_cast<const char*>(rx_.get()), rx_len_); break;
      case 0x8: Serial.println("[cloud] server closed"); ws_close(); set_state(proto::CloudState::connecting, "closed by server"); next_connect_ms_ = now + 5000; return;
      case 0x9: ws_send_frame(0xA, rx_.get(), rx_len_); break;
      default: break;
    }
    if (rx_cap_ > 4096) { rx_.reset(); rx_cap_ = 0; }  // give a big upload buffer back
  }

  if (now - last_ping_ms_ > ws_ping_interval_ms) {
    last_ping_ms_ = now;
    ws_send_text("{\"type\":\"ping\"}");
  }
  if (now - last_rx_ms_ > ws_dead_after_ms) {
    Serial.println("[cloud] no traffic from server, reconnecting");
    ws_close();
    set_state(proto::CloudState::connecting, "server silent");
    next_connect_ms_ = now + 2000;
  }
}

void CloudLink::ws_handle_text(const char* text, size_t len) {
  JsonDocument msg;
  if (deserializeJson(msg, text, len) != DeserializationError::Ok) return;
  const char* type = msg["type"] | "";
  if (!strcmp(type, "ping")) { ws_send_text("{\"type\":\"pong\"}"); return; }
  if (!strcmp(type, "hello")) { Serial.printf("[cloud] hello from server as %s\n", msg["device_name"] | "?"); return; }
  if (!strcmp(type, "invoke")) { ws_handle_invoke(msg.as<JsonVariantConst>()); return; }
}

void CloudLink::ws_handle_invoke(JsonVariantConst msg) {
  const char* call_id = msg["call_id"] | "";
  const char* skill = msg["skill"] | "";
  JsonDocument result;
  String error;
  JsonDocument reply;
  reply["call_id"] = call_id;
  if (run_ && run_(skill, msg["args"], result, error)) {
    reply["type"] = "result";
    reply["result"] = result;
  } else {
    reply["type"] = "error";
    reply["error"] = error.isEmpty() ? "skill failed" : error;
  }
  String out;
  serializeJson(reply, out);
  ws_send_text(out);
}

// ───────────────────────────── Outbound to Jarvis ─────────────────────────────

bool CloudLink::notify(const String& title, const String& body) {
  if (!paired()) return false;
  JsonDocument doc;
  doc["title"] = title;
  doc["body"] = body;
  String json;
  serializeJson(doc, json);
  HttpResponse res;
  return http_post("/api/devices/notify", json, res, true) && res.status == 200;
}

bool CloudLink::ensure_session_id() {
  if (bg_session_.length()) return true;
  JsonDocument doc;
  doc["title"] = String(cfg::device_name_prefix) + " board events";
  String json;
  serializeJson(doc, json);
  HttpResponse res;
  if (!http_post("/api/session/new", json, res, true) || res.status != 200) return false;
  JsonDocument reply;
  if (deserializeJson(reply, res.body) != DeserializationError::Ok) return false;
  String sid = reply["session_id"] | "";
  if (sid.isEmpty()) sid = reply["session"]["session_id"] | "";
  if (sid.isEmpty()) sid = reply["session"]["id"] | "";
  if (sid.isEmpty()) return false;
  bg_session_ = sid;
  save();
  return true;
}

bool CloudLink::invoke_skill(const String& skill, const String& args_json, bool& handled, String& text) {
  handled = false;
  if (!paired()) { text = "not paired"; return false; }
  String json = "{\"skill\":";
  JsonDocument tmp;
  tmp.set(skill);
  serializeJson(tmp, json);
  json += ",\"args\":" + (args_json.isEmpty() ? String("{}") : args_json) + ",\"timeout\":30}";
  HttpResponse res;
  if (!http_post("/api/devices/skills/invoke", json, res, true)) { text = "could not reach Jarvis"; return false; }
  JsonDocument reply;
  deserializeJson(reply, res.body);
  if (res.status == 200 && (reply["ok"] | false)) {
    handled = true;
    if (reply["result"].is<const char*>()) text = reply["result"].as<String>();
    else serializeJson(reply["result"], text);
    if (text.length() > 200) text = text.substring(0, 200);
    return true;
  }
  String err = reply["error"] | "";
  String lower = err; lower.toLowerCase();
  if (res.status == 404 || lower.indexOf("unknown") >= 0 || lower.indexOf("no device") >= 0 ||
      lower.indexOf("not found") >= 0 || lower.indexOf("no such") >= 0) {
    return false;  // not a skill — caller falls back to the agent
  }
  handled = true;
  text = err.isEmpty() ? "skill failed (" + String(res.status) + ")" : err;
  return false;
}

bool CloudLink::agent_turn(const String& prompt, String& error) {
  if (!paired()) { error = "not paired"; return false; }
  if (!ensure_session_id()) { error = "could not open a Jarvis session"; return false; }
  JsonDocument doc;
  doc["session_id"] = bg_session_;
  doc["message"] = prompt;
  String json;
  serializeJson(doc, json);
  HttpResponse res;
  if (!http_post("/api/chat/start", json, res, true)) { error = "could not reach Jarvis"; return false; }
  if (res.status == 404) { bg_session_ = ""; save(); error = "session gone; try again"; return false; }
  if (res.status == 409) { error = "Jarvis is still busy with the previous event"; return false; }
  if (res.status != 200) { error = "Jarvis answered " + String(res.status); return false; }
  return true;
}

}  // namespace jarvis
