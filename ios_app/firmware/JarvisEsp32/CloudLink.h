// Direct link from the board to JarvisCopilot over Wi‑Fi — no phone in the loop.
//
// The board becomes its own paired device of the server: it claims a pairing code
// (handed over by the app), keeps the resulting session, and holds the device-bridge
// WebSocket open, advertising the same `esp32_*` skills the app would. Jarvis then
// invokes and programs it directly; scripts reach Jarvis through `notify` (a visible
// push to the phone) and `background` (a hidden agent turn).
//
// Cloud mode is a boot-time decision: BLE and TLS do not fit in RAM together, so a
// board with a stored session boots without Bluetooth. If Wi‑Fi or the server stays
// unreachable for a few minutes — or the BOOT button is held — it reboots back into
// Bluetooth mode, keeping the session for next time.
//
// Everything here runs from loop(). Network calls block for at most a few seconds.
#ifndef JARVIS_ESP32_CLOUD_LINK_H
#define JARVIS_ESP32_CLOUD_LINK_H

#include <Arduino.h>
#include <NetworkClientSecure.h>
#include <ArduinoJson.h>
#include <functional>
#include <memory>

#include "Protocol.h"

namespace jarvis {

class CloudLink {
 public:
  /// Runs one bridge skill on the board. Fills `result` (a JSON object) and returns
  /// true, or returns false with `error` set.
  using SkillRunner = std::function<bool(const char* skill, JsonVariantConst args, JsonDocument& result, String& error)>;

  CloudLink() = default;
  CloudLink(const CloudLink&) = delete;
  CloudLink& operator=(const CloudLink&) = delete;

  /// Loads the stored session. `skills_json` is the catalogue sent on every connect.
  void begin(const char* skills_json, SkillRunner run);

  /// True when the board should boot without Bluetooth and hold the bridge open.
  bool cloud_mode() const { return mode_; }
  bool paired() const { return cookie_.length() > 0 && server_.length() > 0; }
  proto::CloudState state() const { return state_; }
  const String& server() const { return server_; }
  const String& last_error() const { return last_error_; }
  bool connected() const { return state_ == proto::CloudState::connected; }

  /// Claims `code` at the server (needs Wi‑Fi). On success the session and the
  /// Cloudflare token are stored and cloud mode is armed for the next boot. On failure
  /// the reason is stored too, so it survives the reboot that follows.
  bool pair(const String& url, const String& code, const String& cf_id, const String& cf_secret, String& error);
  /// Stores a pairing request for the next boot. Pairing needs a clean heap (the TLS
  /// handshake wants large contiguous buffers that a running Bluetooth stack has
  /// fragmented), so the board restarts without Bluetooth to carry it out.
  void stage_pairing(const String& url, const String& code, const String& cf_id, const String& cf_secret);
  bool has_pending_pairing() const { return pending_code_.length() > 0; }
  /// Runs the staged pairing (call once Wi‑Fi is up on the pairing boot), then clears it.
  bool run_pending_pairing(String& error);
  void clear_pending_pairing();

  /// Boots into cloud mode next time (session must exist).
  void arm();
  /// Leaves cloud mode for the next boot but keeps the session. `fallback` marks an
  /// automatic exit (server unreachable) so the next boot waits longer before re-arming.
  void disarm(bool fallback = false);
  /// True once, on the boot right after an automatic fallback.
  bool came_from_fallback() const { return from_fallback_; }
  /// Drops everything.
  void forget();

  /// Drives the WebSocket. Call every loop() with the current Wi‑Fi state.
  void service(uint32_t now, bool wifi_connected);

  /// A visible push notification on every paired phone.
  bool notify(const String& title, const String& body);
  /// Runs a device skill on the server directly (no model). `handled` is false when the
  /// server has no such skill, so the caller can fall back to an agent turn.
  bool invoke_skill(const String& skill, const String& args_json, bool& handled, String& text);
  /// A short agent turn in this board's one persistent events session; returns once
  /// the server has accepted it.
  bool agent_turn(const String& prompt, String& error);

  /// True once per state change so the sketch can announce it.
  bool take_state_changed() { const bool c = state_changed_; state_changed_ = false; return c; }
  /// The board wants to reboot into the other mode (fallback or after pairing).
  bool wants_reboot() const { return reboot_at_ != 0 && static_cast<int32_t>(millis() - reboot_at_) >= 0; }
  void request_reboot(uint32_t delay_ms) { reboot_at_ = millis() + delay_ms; }

 private:
  struct HttpResponse {
    int status = 0;
    String body;
    String set_cookie;
  };

  void load();
  void save();
  void set_state(proto::CloudState s, const String& error = "");
  bool parse_server(String& host, uint16_t& port, String& base) const;
  bool http_post(const String& path, const String& json, HttpResponse& out, bool with_session);
  bool ensure_session_id();

  // WebSocket
  bool ws_connect();
  void ws_close();
  bool ws_send_text(const String& text);
  void ws_send_frame(uint8_t opcode, const uint8_t* data, size_t len);
  void ws_poll(uint32_t now);
  void ws_handle_text(const char* text, size_t len);
  void ws_handle_invoke(JsonVariantConst msg);

  String skills_json_;
  SkillRunner run_;

  String server_;      // "https://host[:port][/base]"
  String cookie_;      // hermes_session value
  String cf_id_, cf_secret_;
  String bg_session_;  // parent session for background turns
  bool mode_ = false;
  bool from_fallback_ = false;
  String pending_url_, pending_code_, pending_cf_id_, pending_cf_secret_;

  proto::CloudState state_ = proto::CloudState::off;
  bool state_changed_ = false;
  String last_error_;
  uint32_t reboot_at_ = 0;

  std::unique_ptr<NetworkClientSecure> ws_;
  bool ws_open_ = false;
  uint32_t next_connect_ms_ = 0;
  uint32_t backoff_ms_ = 5000;
  uint32_t last_rx_ms_ = 0;
  uint32_t last_ping_ms_ = 0;
  uint32_t offline_since_ms_ = 0;

  // Inbound frame reassembly.
  std::unique_ptr<uint8_t[]> rx_;
  size_t rx_cap_ = 0;
  size_t rx_len_ = 0;
  size_t rx_need_ = 0;     // payload length once the header is parsed
  uint8_t rx_opcode_ = 0;
  bool rx_header_done_ = false;
  uint8_t hdr_[14];
  size_t hdr_len_ = 0;
};

}  // namespace jarvis

#endif  // JARVIS_ESP32_CLOUD_LINK_H
