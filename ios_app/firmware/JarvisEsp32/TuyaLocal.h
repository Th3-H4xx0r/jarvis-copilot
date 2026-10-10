// Local link from the board to a Tuya (Smart Life) Wi‑Fi device on the same LAN — the
// PHYSEN door-sensor hub — relayed to Jarvis over the CloudLink bridge.
//
// The board holds one Tuya LAN session (TCP 6668, protocol 3.3 / 3.4 / 3.5, see
// TuyaCodec.h + TuyaSession.h) and turns every data-point report into a `door_report`
// event; `door_link` events carry the link state on every change and every 30 s (the
// server's liveness signal). If the hub's IP or protocol version isn't configured, it is
// learned from the hub's UDP discovery broadcasts (6666 / 6667 / 7000), or — IP given,
// version not — by trying 3.5, then 3.4, then 3.3.
//
// Bridge skills (see JarvisEsp32.ino): esp32_door_configure / _set / _query / _status /
// _forget. The local key lives in NVS only; it is never logged or returned.
//
// Everything runs from loop() and never blocks, except esp32_door_query, which waits up
// to 3 s for the hub's answer. Sockets are raw lwIP so the TCP connect is non-blocking too.
#ifndef JARVIS_ESP32_TUYA_LOCAL_H
#define JARVIS_ESP32_TUYA_LOCAL_H

#include <Arduino.h>
#include <ArduinoJson.h>
#include <IPAddress.h>
#include <functional>
#include <memory>

#include "TuyaSession.h"

namespace jarvis {

class TuyaLocal {
 public:
  enum class LinkState : uint8_t { unconfigured, connecting, connected, handshake_failed, unreachable };
  /// Delivers one bridge event; false when it couldn't go out (bridge down).
  using EventSink = std::function<bool(const char* name, const String& data_json)>;

  TuyaLocal();
  ~TuyaLocal();
  TuyaLocal(const TuyaLocal&) = delete;
  TuyaLocal& operator=(const TuyaLocal&) = delete;

  /// Loads the stored hub config. Call once from setup().
  void begin(EventSink sink);
  /// Drives discovery, the TCP session and reporting. Call every loop().
  void service(uint32_t now, bool wifi_up, bool cloud_up);
  /// Runs one esp32_door_* skill. False (with `error`) only for bad arguments.
  bool run_skill(const String& name, JsonVariantConst args, JsonDocument& result, String& error);

  bool configured() const { return configured_; }
  LinkState state() const { return state_; }
  static const char* state_name(LinkState s);

 private:
  enum class Sock : uint8_t { none, connecting, open };

  // Config / NVS
  void load();
  void save_config();
  void save_learned();
  void clear_stored();
  tuya::Version effective_version() const;
  bool probing() const { return effective_version() == tuya::Version::unknown; }

  // Skills
  bool skill_configure(JsonVariantConst args, JsonDocument& result, String& error);
  bool skill_set(JsonVariantConst args, JsonDocument& result, String& error);
  bool skill_query(JsonDocument& result);
  void skill_status(JsonDocument& result) const;
  void skill_forget(JsonDocument& result);

  // TCP
  void open_tcp(uint32_t now);
  void poll_connect(uint32_t now);
  void begin_session(uint32_t now);
  void pump(uint32_t now);
  bool write_out();
  void close_tcp();
  void on_ready(uint32_t now);
  void drop(uint32_t now, tuya::Session::Failure failure, const String& detail);
  void tcp_failed(uint32_t now, const String& why);
  void schedule_retry(uint32_t now);

  // Discovery
  void start_discovery(uint32_t now);
  void stop_discovery();
  void poll_discovery(uint32_t now);
  void on_broadcast(const char* json, const IPAddress& from, uint32_t now);

  // Reporting
  void set_state(LinkState s, const String& error = "");
  void emit_link(uint32_t now);
  void handle_report(const tuya::Session::Report& r, uint32_t now);
  void deliver_report(const String& json);
  void flush_queue();

  uint32_t unix_now() const;
  bool time_ok() const;
  void restart(uint32_t now);

  EventSink sink_;

  // Stored config (local key never leaves this object).
  bool configured_ = false;
  String dev_id_;
  uint8_t key_[16] = {};
  IPAddress cfg_ip_;
  tuya::Version cfg_version_ = tuya::Version::unknown;
  IPAddress learned_ip_;
  tuya::Version learned_version_ = tuya::Version::unknown;

  // Where the next attempt goes.
  IPAddress target_ip_;
  uint8_t probe_idx_ = 0;
  tuya::Version attempt_version_ = tuya::Version::unknown;

  // TCP session
  tuya::Session session_;
  int sock_ = -1;
  Sock sock_phase_ = Sock::none;
  uint32_t connect_started_ms_ = 0;
  bool conn_ready_ = false;
  tuya::Bytes tx_;
  uint32_t next_attempt_ms_ = 0;
  uint32_t backoff_ms_ = 1000;
  uint8_t tcp_failures_ = 0;
  uint8_t no_answer_count_ = 0;
  bool wifi_was_up_ = false;
  uint32_t wifi_up_since_ms_ = 0;
  bool sntp_started_ = false;

  // Discovery (UDP 6666 / 6667 / 7000)
  int udp_[3] = {-1, -1, -1};
  bool discovering_ = false;
  uint32_t discovery_started_ms_ = 0;
  uint32_t last_devinfo_ms_ = 0;
  std::unique_ptr<uint8_t[]> udp_buf_;

  // Link state as the server sees it
  LinkState state_ = LinkState::unconfigured;
  String error_;
  uint32_t last_link_ms_ = 0;
  bool link_dirty_ = false;
  bool cloud_was_up_ = false;

  // door_report
  static constexpr size_t queue_cap = 16;
  String queue_[queue_cap];
  size_t q_head_ = 0, q_count_ = 0;
  uint32_t report_seq_ = 0;
  uint32_t last_report_ms_ = 0;
  bool have_report_ = false;
  uint32_t dev_t_ = 0;          // last plausible unix time the hub reported
  uint32_t dev_t_at_ms_ = 0;

  // esp32_door_query waiting for its answer
  JsonDocument* capture_ = nullptr;
  bool captured_ = false;
};

}  // namespace jarvis

#endif  // JARVIS_ESP32_TUYA_LOCAL_H
