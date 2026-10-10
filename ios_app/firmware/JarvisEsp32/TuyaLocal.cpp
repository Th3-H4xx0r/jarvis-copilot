#include "TuyaLocal.h"

#include <WiFi.h>
#include <Preferences.h>
#include <esp_random.h>
#include <esp_sntp.h>
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <lwip/sockets.h>

namespace jarvis {

using tuya::Session;
using tuya::Version;

namespace {
// NVS. The local key is stored as 16 raw bytes and never read back out of this file.
constexpr const char* prefs_namespace = "jvdoor";
constexpr const char* key_dev = "id";
constexpr const char* key_local = "key";
constexpr const char* key_ip = "ip";
constexpr const char* key_ver = "ver";
constexpr const char* key_learned_ip = "lip";
constexpr const char* key_learned_ver = "lver";

constexpr uint16_t tcp_port = 6668;
constexpr uint16_t udp_ports[3] = {6666, 6667, 7000};  // 3.1 plaintext, 3.3+ ECB, 3.5 GCM
constexpr uint32_t connect_timeout_ms = 3000;
constexpr uint32_t backoff_min_ms = 1000;
constexpr uint32_t backoff_max_ms = 30000;
constexpr uint32_t probe_step_ms = 300;          // between version probes on one IP
constexpr uint32_t link_every_ms = 30000;        // door_link heartbeat to the server
constexpr uint32_t devinfo_every_ms = 6000;      // "who's there" to UDP 7000 (wakes 3.5 hubs)
constexpr uint32_t discovery_grace_ms = 30000;   // no IP yet: "connecting" this long, then "unreachable"
constexpr uint32_t sntp_wait_ms = 5000;          // first attempt waits this long for a real clock
constexpr uint32_t query_wait_ms = 3000;
constexpr uint8_t tcp_failures_before_discovery = 3;
constexpr uint8_t silent_attempts_before_key_blame = 2;
constexpr size_t udp_buf_len = 1024;
constexpr uint32_t plausible_unix = 1600000000u;
constexpr Version probe_order[3] = {Version::v35, Version::v34, Version::v33};

void fill_random(uint8_t* out, size_t n) { esp_fill_random(out, n); }

bool due(uint32_t now, uint32_t at) { return static_cast<int32_t>(now - at) >= 0; }

bool ip_set(const IPAddress& ip) { return static_cast<uint32_t>(ip) != 0; }

String ip_text(const IPAddress& ip) { return ip_set(ip) ? ip.toString() : String(""); }

Version stored_version(uint8_t v) {
  return (v == 33 || v == 34 || v == 35) ? static_cast<Version>(v) : Version::unknown;
}

// Spliced raw into the hub's JSON payloads, so only the characters Tuya ids use.
bool valid_dev_id(const char* s) {
  const size_t n = strlen(s);
  if (n == 0 || n > 64) return false;
  for (size_t i = 0; i < n; ++i) {
    const char c = s[i];
    if (!isalnum(static_cast<unsigned char>(c)) && c != '_' && c != '-') return false;
  }
  return true;
}

bool is_dp_id(const char* s) {
  if (s == nullptr || *s == 0 || strlen(s) > 5) return false;
  for (; *s; ++s) {
    if (!isdigit(static_cast<unsigned char>(*s))) return false;
  }
  return true;
}
}  // namespace

TuyaLocal::TuyaLocal() : session_(fill_random) {}

TuyaLocal::~TuyaLocal() {
  close_tcp();
  stop_discovery();
  tuya::secure_zero(key_, sizeof(key_));
}

const char* TuyaLocal::state_name(LinkState s) {
  switch (s) {
    case LinkState::connecting: return "connecting";
    case LinkState::connected: return "connected";
    case LinkState::handshake_failed: return "handshake_failed";
    case LinkState::unreachable: return "unreachable";
    default: return "unconfigured";
  }
}

// ───────────────────────────── Config ─────────────────────────────

void TuyaLocal::begin(EventSink sink) {
  sink_ = std::move(sink);
  load();
  if (!configured_) {
    Serial.println("[door] no door hub configured");
    return;
  }
  target_ip_ = ip_set(learned_ip_) ? learned_ip_ : cfg_ip_;
  state_ = LinkState::connecting;
  Serial.printf("[door] hub %s, ip %s, protocol %s\n", dev_id_.c_str(),
                ip_set(target_ip_) ? target_ip_.toString().c_str() : "from broadcasts",
                tuya::version_name(effective_version()));
}

void TuyaLocal::load() {
  Preferences prefs;
  // Read-write so a board that never had a hub doesn't log an NVS "not found" each boot.
  if (!prefs.begin(prefs_namespace, /*readOnly=*/false)) return;
  dev_id_ = prefs.getString(key_dev, "");
  configured_ = dev_id_.length() > 0 && prefs.getBytesLength(key_local) == sizeof(key_) &&
                prefs.getBytes(key_local, key_, sizeof(key_)) == sizeof(key_);
  cfg_ip_ = IPAddress();
  const String ip = prefs.getString(key_ip, "");
  if (ip.length()) cfg_ip_.fromString(ip);
  cfg_version_ = stored_version(prefs.getUChar(key_ver, 0));
  learned_ip_ = IPAddress();
  const String lip = prefs.getString(key_learned_ip, "");
  if (lip.length()) learned_ip_.fromString(lip);
  learned_version_ = stored_version(prefs.getUChar(key_learned_ver, 0));
  prefs.end();
  if (!configured_) {
    dev_id_ = "";
    tuya::secure_zero(key_, sizeof(key_));
  }
}

void TuyaLocal::save_config() {
  Preferences prefs;
  if (!prefs.begin(prefs_namespace, /*readOnly=*/false)) return;
  prefs.putString(key_dev, dev_id_);
  prefs.putBytes(key_local, key_, sizeof(key_));
  prefs.putString(key_ip, ip_text(cfg_ip_));
  prefs.putUChar(key_ver, static_cast<uint8_t>(cfg_version_));
  if (prefs.isKey(key_learned_ip)) prefs.remove(key_learned_ip);
  if (prefs.isKey(key_learned_ver)) prefs.remove(key_learned_ver);
  prefs.end();
}

void TuyaLocal::save_learned() {
  Preferences prefs;
  if (!prefs.begin(prefs_namespace, /*readOnly=*/false)) return;
  prefs.putString(key_learned_ip, ip_text(learned_ip_));
  prefs.putUChar(key_learned_ver, static_cast<uint8_t>(learned_version_));
  prefs.end();
}

void TuyaLocal::clear_stored() {
  Preferences prefs;
  if (!prefs.begin(prefs_namespace, /*readOnly=*/false)) return;
  prefs.clear();
  prefs.end();
}

Version TuyaLocal::effective_version() const {
  return cfg_version_ != Version::unknown ? cfg_version_ : learned_version_;
}

void TuyaLocal::restart(uint32_t now) {
  close_tcp();
  stop_discovery();
  target_ip_ = ip_set(learned_ip_) ? learned_ip_ : cfg_ip_;
  probe_idx_ = 0;
  tcp_failures_ = 0;
  no_answer_count_ = 0;
  backoff_ms_ = backoff_min_ms;
  next_attempt_ms_ = now;
  set_state(LinkState::connecting);
}

// ───────────────────────────── Service ─────────────────────────────

uint32_t TuyaLocal::unix_now() const {
  const time_t t = time(nullptr);
  if (t > static_cast<time_t>(plausible_unix)) return static_cast<uint32_t>(t);
  if (dev_t_ != 0) return dev_t_ + (millis() - dev_t_at_ms_) / 1000;
  return 0;
}

bool TuyaLocal::time_ok() const {
  return time(nullptr) > static_cast<time_t>(plausible_unix) || dev_t_ != 0;
}

void TuyaLocal::service(uint32_t now, bool wifi_up, bool cloud_up) {
  if (cloud_up && !cloud_was_up_) {
    // Bridge (re)connected: queued reports first, in order, then where the link stands.
    flush_queue();
    if (configured_) emit_link(now);
  }
  cloud_was_up_ = cloud_up;
  if (cloud_up && q_count_ > 0) flush_queue();
  if (!configured_) return;

  if (!wifi_up) {
    if (sock_phase_ != Sock::none) close_tcp();
    stop_discovery();
    wifi_was_up_ = false;
    set_state(LinkState::unreachable, "Wi-Fi down");
  } else {
    if (!wifi_was_up_) {
      wifi_was_up_ = true;
      wifi_up_since_ms_ = now;
      next_attempt_ms_ = now;
      if (!sntp_started_) {
        // Tuya CONTROL/DP_QUERY carry a timestamp; nothing else on the board sets the clock.
        sntp_started_ = true;
        if (!esp_sntp_enabled()) configTime(0, 0, "pool.ntp.org", "time.google.com");
      }
    }
    if (discovering_) poll_discovery(now);
    switch (sock_phase_) {
      case Sock::none:
        if (!ip_set(target_ip_)) {
          start_discovery(now);
          if (now - discovery_started_ms_ > discovery_grace_ms) {
            set_state(LinkState::unreachable, "hub not seen in LAN broadcasts");
          }
        } else if (due(now, next_attempt_ms_) && (time_ok() || now - wifi_up_since_ms_ > sntp_wait_ms)) {
          open_tcp(now);
        }
        break;
      case Sock::connecting:
        poll_connect(now);
        break;
      case Sock::open:
        pump(now);
        break;
    }
  }
  if (configured_ && now - last_link_ms_ >= link_every_ms) emit_link(now);
}

// ───────────────────────────── TCP ─────────────────────────────

void TuyaLocal::open_tcp(uint32_t now) {
  attempt_version_ = probing() ? probe_order[probe_idx_ % 3] : effective_version();
  tx_.clear();
  conn_ready_ = false;
  sock_ = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if (sock_ < 0) { tcp_failed(now, "no free socket"); return; }
  fcntl(sock_, F_SETFL, fcntl(sock_, F_GETFL, 0) | O_NONBLOCK);
  int one = 1;
  setsockopt(sock_, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
  sockaddr_in addr = {};
  addr.sin_family = AF_INET;
  addr.sin_port = htons(tcp_port);
  addr.sin_addr.s_addr = static_cast<uint32_t>(target_ip_);
  connect_started_ms_ = now;
  sock_phase_ = Sock::connecting;
  const int rc = connect(sock_, reinterpret_cast<sockaddr*>(&addr), sizeof(addr));
  if (rc == 0) {
    begin_session(now);
  } else if (errno != EINPROGRESS) {
    tcp_failed(now, strerror(errno));
  }
}

void TuyaLocal::poll_connect(uint32_t now) {
  fd_set writable;
  FD_ZERO(&writable);
  FD_SET(sock_, &writable);
  timeval tv = {0, 0};
  const int r = select(sock_ + 1, nullptr, &writable, nullptr, &tv);
  if (r > 0) {
    int err = 0;
    socklen_t len = sizeof(err);
    getsockopt(sock_, SOL_SOCKET, SO_ERROR, &err, &len);
    if (err == 0) begin_session(now);
    else tcp_failed(now, strerror(err));
    return;
  }
  if (r < 0) { tcp_failed(now, "select failed"); return; }
  if (now - connect_started_ms_ > connect_timeout_ms) tcp_failed(now, "timed out");
}

void TuyaLocal::begin_session(uint32_t now) {
  sock_phase_ = Sock::open;
  conn_ready_ = false;
  Serial.printf("[door] tcp up to %s, speaking %s\n", target_ip_.toString().c_str(),
                tuya::version_name(attempt_version_));
  session_.start(attempt_version_, std::string(dev_id_.c_str(), dev_id_.length()), key_, now, unix_now());
  if (!write_out()) drop(now, Session::Failure::no_answer, "socket write failed");
}

void TuyaLocal::pump(uint32_t now) {
  if (sock_phase_ != Sock::open) return;
  const uint32_t unix_s = unix_now();
  bool closed = false;
  uint8_t buf[512];
  for (int i = 0; i < 8; ++i) {
    const int n = recv(sock_, buf, sizeof(buf), MSG_DONTWAIT);
    if (n > 0) { session_.feed(buf, static_cast<size_t>(n), now, unix_s); continue; }
    if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) break;
    closed = true;  // 0 = orderly close, <0 = reset / error
    break;
  }
  session_.tick(now, unix_s);
  const bool wrote = write_out();
  // door_link "connected" goes out ahead of the connect-time snapshot, and reports go
  // out before a failure is acted on (a frame can carry data and still end the session).
  if (session_.ready() && !conn_ready_) on_ready(now);
  Session::Report report;
  while (session_.take_report(report)) handle_report(report, now);
  if (session_.phase() == Session::Phase::failed) {
    drop(now, session_.failure(), String(session_.detail().c_str()));
    return;
  }
  if (closed || !wrote) {
    drop(now, conn_ready_ ? Session::Failure::went_silent : Session::Failure::no_answer,
         closed ? "hub closed the connection" : "socket write failed");
  }
}

bool TuyaLocal::write_out() {
  session_.take_output(tx_);
  while (!tx_.empty() && sock_ >= 0) {
    const int n = send(sock_, tx_.data(), tx_.size(), MSG_DONTWAIT);
    if (n > 0) {
      tx_.erase(tx_.begin(), tx_.begin() + n);
      continue;
    }
    if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return true;  // rest goes next loop
    return false;
  }
  return true;
}

void TuyaLocal::close_tcp() {
  if (sock_ >= 0) ::close(sock_);
  sock_ = -1;
  sock_phase_ = Sock::none;
  conn_ready_ = false;
  session_.reset();
  tx_.clear();
}

void TuyaLocal::on_ready(uint32_t now) {
  (void)now;
  conn_ready_ = true;
  tcp_failures_ = 0;
  no_answer_count_ = 0;
  probe_idx_ = 0;
  backoff_ms_ = backoff_min_ms;
  bool learned = false;
  if (cfg_version_ == Version::unknown && learned_version_ != attempt_version_) {
    learned_version_ = attempt_version_;
    learned = true;
  }
  if (target_ip_ != learned_ip_ && target_ip_ != cfg_ip_) {
    learned_ip_ = target_ip_;
    learned = true;
  }
  if (learned) save_learned();
  stop_discovery();
  set_state(LinkState::connected);
  Serial.printf("[door] session up with %s (protocol %s)\n", target_ip_.toString().c_str(),
                tuya::version_name(attempt_version_));
}

void TuyaLocal::schedule_retry(uint32_t now) {
  next_attempt_ms_ = now + backoff_ms_;
  backoff_ms_ = backoff_ms_ * 2 > backoff_max_ms ? backoff_max_ms : backoff_ms_ * 2;
}

void TuyaLocal::tcp_failed(uint32_t now, const String& why) {
  close_tcp();
  if (tcp_failures_ < 255) ++tcp_failures_;
  set_state(LinkState::unreachable, "can't reach " + target_ip_.toString() + ":6668 (" + why + ")");
  if (tcp_failures_ >= tcp_failures_before_discovery && !discovering_) {
    Serial.println("[door] hub unreachable; listening for its broadcasts in case the IP changed");
    start_discovery(now);
  }
  schedule_retry(now);
}

// A session ended. Before it was up, the failure says whether to blame the key or the
// protocol version; after, it just reconnects.
void TuyaLocal::drop(uint32_t now, Session::Failure failure, const String& detail) {
  const bool was_ready = conn_ready_;
  const Version tried = attempt_version_;
  close_tcp();
  if (was_ready) {
    Serial.printf("[door] session lost: %s\n", detail.c_str());
    set_state(LinkState::connecting, detail);
    backoff_ms_ = backoff_min_ms;
    next_attempt_ms_ = now + backoff_min_ms;
    return;
  }
  Serial.printf("[door] %s handshake failed: %s\n", tuya::version_name(tried), detail.c_str());
  using F = Session::Failure;
  if (probing()) {
    if (failure == F::key_rejected) {
      // It answered in this version's framing, so that's its version; the key is what's wrong.
      learned_version_ = tried;
      set_state(LinkState::handshake_failed, detail);
      schedule_retry(now);
      return;
    }
    if (++probe_idx_ < 3) {
      next_attempt_ms_ = now + probe_step_ms;
      return;
    }
    probe_idx_ = 0;
    set_state(LinkState::handshake_failed, "no protocol version answered (tried 3.5, 3.4, 3.3); local key?");
    schedule_retry(now);
    return;
  }
  if (failure == F::key_rejected) {
    set_state(LinkState::handshake_failed, detail);
    schedule_retry(now);
    return;
  }
  if (failure == F::wrong_framing && cfg_version_ == Version::unknown) {
    // The version we learned doesn't match what the hub speaks: probe again.
    learned_version_ = Version::unknown;
    probe_idx_ = 0;
    next_attempt_ms_ = now + probe_step_ms;
    return;
  }
  // A hub with another key usually just drops our hello, so repeated silence after a
  // good TCP connect is blamed on the key too.
  if (++no_answer_count_ >= silent_attempts_before_key_blame) {
    set_state(LinkState::handshake_failed,
              String("no ") + tuya::version_name(tried) + " handshake (" + detail + "); local key?");
  }
  schedule_retry(now);
}

// ───────────────────────────── Discovery ─────────────────────────────

void TuyaLocal::start_discovery(uint32_t now) {
  if (discovering_) return;
  discovering_ = true;
  discovery_started_ms_ = now;
  last_devinfo_ms_ = now - devinfo_every_ms;  // ask right away
  if (!udp_buf_) udp_buf_.reset(new uint8_t[udp_buf_len]);
  for (int i = 0; i < 3; ++i) {
    const int fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (fd < 0) continue;
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &one, sizeof(one));
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
    sockaddr_in addr = {};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(udp_ports[i]);
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) < 0) {
      Serial.printf("[door] can't listen on UDP %u\n", udp_ports[i]);
      ::close(fd);
      continue;
    }
    udp_[i] = fd;
  }
  Serial.println("[door] listening for Tuya discovery broadcasts");
}

void TuyaLocal::stop_discovery() {
  for (int& fd : udp_) {
    if (fd >= 0) ::close(fd);
    fd = -1;
  }
  discovering_ = false;
  udp_buf_.reset();
}

void TuyaLocal::poll_discovery(uint32_t now) {
  if (!udp_buf_) return;
  if (udp_[2] >= 0 && now - last_devinfo_ms_ >= devinfo_every_ms) {
    last_devinfo_ms_ = now;
    uint8_t iv[12];
    esp_fill_random(iv, sizeof(iv));
    const tuya::Bytes req = tuya::devinfo_request(WiFi.localIP().toString().c_str(), iv);
    sockaddr_in to = {};
    to.sin_family = AF_INET;
    to.sin_port = htons(7000);
    to.sin_addr.s_addr = htonl(INADDR_BROADCAST);
    sendto(udp_[2], req.data(), req.size(), 0, reinterpret_cast<sockaddr*>(&to), sizeof(to));
  }
  for (int i = 0; i < 3; ++i) {
    if (udp_[i] < 0) continue;
    for (int k = 0; k < 4; ++k) {
      sockaddr_in from = {};
      socklen_t from_len = sizeof(from);
      const int n = recvfrom(udp_[i], udp_buf_.get(), udp_buf_len, MSG_DONTWAIT,
                             reinterpret_cast<sockaddr*>(&from), &from_len);
      if (n <= 0) break;
      std::string json;
      if (tuya::decode_broadcast(udp_buf_.get(), static_cast<size_t>(n), json)) {
        on_broadcast(json.c_str(), IPAddress(from.sin_addr.s_addr), now);
      }
      if (!udp_buf_) return;  // on_broadcast may have connected and stopped discovery
    }
  }
}

void TuyaLocal::on_broadcast(const char* json, const IPAddress& from, uint32_t now) {
  JsonDocument doc;
  if (deserializeJson(doc, json) != DeserializationError::Ok) return;
  if (doc["from"].is<const char*>()) return;  // another app's (or our own) discovery request
  const char* gw = doc["gwId"] | "";
  const char* dev = doc["devId"] | "";
  if (dev_id_ != gw && dev_id_ != dev) return;
  IPAddress ip;
  if (!ip.fromString(doc["ip"] | "")) ip = from;
  const Version v = tuya::parse_version(doc["version"] | "");
  bool changed = false;
  if (ip != target_ip_) {
    target_ip_ = ip;
    learned_ip_ = ip;
    changed = true;
  }
  if (cfg_version_ == Version::unknown && v != Version::unknown && v != learned_version_) {
    learned_version_ = v;
    probe_idx_ = 0;
    changed = true;
  }
  if (!changed) return;
  Serial.printf("[door] hub broadcasts from %s, protocol %s\n", ip.toString().c_str(), tuya::version_name(v));
  save_learned();
  tcp_failures_ = 0;
  no_answer_count_ = 0;
  if (sock_phase_ == Sock::none) next_attempt_ms_ = now;
}

// ───────────────────────────── Reporting ─────────────────────────────

void TuyaLocal::set_state(LinkState s, const String& error) {
  if (s == state_ && error == error_) return;
  const bool changed = s != state_;
  state_ = s;
  error_ = error;
  if (!changed) return;
  Serial.printf("[door] link %s%s%s\n", state_name(s), error.length() ? ": " : "", error.c_str());
  emit_link(millis());
}

void TuyaLocal::emit_link(uint32_t now) {
  last_link_ms_ = now;
  JsonDocument d;
  d["state"] = state_name(state_);
  d["ip"] = ip_text(target_ip_);
  d["version"] = tuya::version_name(conn_ready_ ? attempt_version_ : effective_version());
  d["rtt_ms"] = conn_ready_ ? session_.rtt_ms() : -1;
  d["error"] = error_;
  d["rssi"] = WiFi.RSSI();
  String json;
  serializeJson(d, json);
  if (sink_) sink_("door_link", json);
}

void TuyaLocal::handle_report(const Session::Report& r, uint32_t now) {
  JsonDocument in;
  if (deserializeJson(in, r.json.c_str(), r.json.size()) != DeserializationError::Ok) return;
  JsonObjectConst root = in.as<JsonObjectConst>();
  JsonObjectConst data = root["data"].as<JsonObjectConst>();
  JsonVariantConst dps = root["dps"];
  if (!dps.is<JsonObjectConst>()) dps = data["dps"];
  if (!dps.is<JsonObjectConst>()) return;  // an ack or an error object, not data points
  JsonVariantConst tv = root["t"];
  if (tv.isNull()) tv = data["t"];
  uint32_t t = 0;
  if (tv.is<const char*>()) t = static_cast<uint32_t>(strtoul(tv.as<const char*>(), nullptr, 10));
  else if (tv.is<uint32_t>()) t = tv.as<uint32_t>();
  if (t > plausible_unix) {
    dev_t_ = t;
    dev_t_at_ms_ = now;
  } else {
    // No time from the hub: stamp when the board heard it, so a report queued while the bridge was
    // down arrives dated and the server treats it as history, not a fresh opening.
    const time_t clock = time(nullptr);
    if (clock > static_cast<time_t>(plausible_unix)) t = static_cast<uint32_t>(clock);
  }

  JsonDocument out;
  out["dps"] = dps;
  out["t"] = t;
  out["seq"] = ++report_seq_;
  out["query"] = r.query;
  JsonVariantConst cid = root["cid"];
  if (cid.isNull()) cid = data["cid"];
  if (cid.is<const char*>()) out["cid"] = cid;  // only gateway hubs with sub-devices send one
  String json;
  serializeJson(out, json);
  last_report_ms_ = now;
  have_report_ = true;
  if (capture_ != nullptr && r.query) {
    (*capture_)["dps"] = dps;
    captured_ = true;
  }
  Serial.printf("[door] report #%u%s %s\n", static_cast<unsigned>(report_seq_), r.query ? " (query)" : "",
                json.c_str());
  deliver_report(json);
}

void TuyaLocal::deliver_report(const String& json) {
  flush_queue();
  if (q_count_ == 0 && sink_ && sink_("door_report", json)) return;
  if (q_count_ == queue_cap) {  // keep the newest 16
    queue_[q_head_] = String();
    q_head_ = (q_head_ + 1) % queue_cap;
    --q_count_;
  }
  queue_[(q_head_ + q_count_) % queue_cap] = json;
  ++q_count_;
}

void TuyaLocal::flush_queue() {
  while (q_count_ > 0 && sink_ && sink_("door_report", queue_[q_head_])) {
    queue_[q_head_] = String();
    q_head_ = (q_head_ + 1) % queue_cap;
    --q_count_;
  }
}

// ───────────────────────────── Skills ─────────────────────────────

bool TuyaLocal::run_skill(const String& name, JsonVariantConst args, JsonDocument& result, String& error) {
  if (name == "esp32_door_configure") return skill_configure(args, result, error);
  if (name == "esp32_door_set") return skill_set(args, result, error);
  if (name == "esp32_door_query") return skill_query(result);
  if (name == "esp32_door_status") { skill_status(result); return true; }
  if (name == "esp32_door_forget") { skill_forget(result); return true; }
  error = "unknown skill";
  return false;
}

bool TuyaLocal::skill_configure(JsonVariantConst args, JsonDocument& result, String& error) {
  const char* id = args["dev_id"] | "";
  const char* key = args["local_key"] | "";
  const char* ip = args["ip"] | "";
  const char* ver = args["version"] | "auto";
  if (!valid_dev_id(id)) { error = "dev_id must be 1-64 letters, digits, '_' or '-'"; return false; }
  if (strlen(key) != sizeof(key_)) { error = "local_key must be exactly 16 characters"; return false; }
  IPAddress new_ip;
  if (*ip && (!new_ip.fromString(ip) || !ip_set(new_ip))) { error = "ip must be an IPv4 address"; return false; }
  const Version v = tuya::parse_version(ver);
  if (v == Version::unknown && *ver && strcmp(ver, "auto") != 0) {
    error = "version must be 3.3, 3.4, 3.5 or auto";
    return false;
  }
  const bool same = configured_ && dev_id_ == id && memcmp(key_, key, sizeof(key_)) == 0 && new_ip == cfg_ip_ &&
                    v == cfg_version_;
  if (!(same && state_ == LinkState::connected)) {
    dev_id_ = id;
    memcpy(key_, key, sizeof(key_));
    cfg_ip_ = new_ip;
    cfg_version_ = v;
    if (!same) {
      learned_ip_ = IPAddress();
      learned_version_ = Version::unknown;
      save_config();
    }
    configured_ = true;
    Serial.printf("[door] hub %s configured (ip %s, protocol %s)\n", id, *ip ? ip : "from broadcasts",
                  tuya::version_name(v));
    restart(millis());
  }
  result["ok"] = true;
  result["state"] = state_name(state_);
  return true;
}

bool TuyaLocal::skill_set(JsonVariantConst args, JsonDocument& result, String& error) {
  JsonObjectConst dps = args["dps"].as<JsonObjectConst>();
  if (dps.isNull() || dps.size() == 0) { error = "dps must be a non-empty object of {\"<dp id>\": value}"; return false; }
  for (JsonPairConst kv : dps) {
    if (!is_dp_id(kv.key().c_str())) { error = "dp ids are numbers, e.g. {\"1\": true}"; return false; }
  }
  if (!conn_ready_ || sock_phase_ != Sock::open) {
    result["ok"] = false;
    result["error"] = "hub not connected";
    result["state"] = state_name(state_);
    return true;
  }
  String json;
  serializeJson(dps, json);
  session_.control(std::string(json.c_str(), json.length()), unix_now());
  if (!write_out()) {
    drop(millis(), Session::Failure::went_silent, "socket write failed");
    result["ok"] = false;
    result["error"] = "write to the hub failed";
    result["state"] = state_name(state_);
    return true;
  }
  result["ok"] = true;
  return true;
}

bool TuyaLocal::skill_query(JsonDocument& result) {
  if (!conn_ready_ || sock_phase_ != Sock::open) {
    result["ok"] = false;
    result["error"] = "hub not connected";
    result["state"] = state_name(state_);
    return true;
  }
  session_.query(unix_now());
  if (!write_out()) {
    drop(millis(), Session::Failure::went_silent, "socket write failed");
    result["ok"] = false;
    result["error"] = "write to the hub failed";
    result["state"] = state_name(state_);
    return true;
  }
  // Pump the socket until the snapshot comes back (it also goes out as a door_report).
  capture_ = &result;
  captured_ = false;
  const uint32_t start = millis();
  while (!captured_ && sock_phase_ == Sock::open && millis() - start < query_wait_ms) {
    delay(10);
    pump(millis());
  }
  capture_ = nullptr;
  if (!captured_ && sock_phase_ != Sock::open) {
    result["ok"] = false;
    result["error"] = "hub connection dropped";
    result["state"] = state_name(state_);
    return true;
  }
  result["ok"] = true;
  if (!captured_) result["pending"] = true;
  return true;
}

void TuyaLocal::skill_status(JsonDocument& result) const {
  result["configured"] = configured_;
  result["state"] = state_name(state_);
  result["ip"] = ip_text(target_ip_);
  result["version"] = tuya::version_name(conn_ready_ ? attempt_version_ : effective_version());
  result["dev_id"] = dev_id_;
  result["last_report_age_s"] = have_report_ ? static_cast<int32_t>((millis() - last_report_ms_) / 1000) : -1;
  result["rtt_ms"] = conn_ready_ ? session_.rtt_ms() : -1;
  result["rssi"] = WiFi.RSSI();
  result["error"] = error_;
}

void TuyaLocal::skill_forget(JsonDocument& result) {
  close_tcp();
  stop_discovery();
  clear_stored();
  tuya::secure_zero(key_, sizeof(key_));
  configured_ = false;
  dev_id_ = "";
  cfg_ip_ = learned_ip_ = target_ip_ = IPAddress();
  cfg_version_ = learned_version_ = Version::unknown;
  Serial.println("[door] hub forgotten");
  set_state(LinkState::unconfigured);
  result["ok"] = true;
  result["state"] = state_name(state_);
}

}  // namespace jarvis
