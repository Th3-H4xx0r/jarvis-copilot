// Wi‑Fi station + single-client TCP transport for the Jarvis protocol.
//
// Owns the stored credentials (NVS via Preferences), the join/retry state machine,
// mDNS registration, and one TCP client at a time. It hands complete frames to the
// sketch through `on_frame` and never interprets them itself, except for tracking
// whether the client has passed AUTH — the sketch decides that and calls
// `mark_authenticated()`.
//
// Everything here runs from loop(); nothing is called from another task.
#ifndef JARVIS_ESP32_WIFI_LINK_H
#define JARVIS_ESP32_WIFI_LINK_H

#include <Arduino.h>
#include <WiFi.h>
#include <functional>

#include "Protocol.h"

namespace jarvis {

class WifiLink {
 public:
  using FrameHandler = std::function<void(const uint8_t* frame, size_t len)>;

  WifiLink() = default;
  WifiLink(const WifiLink&) = delete;
  WifiLink& operator=(const WifiLink&) = delete;

  /// Loads stored credentials and starts joining if there are any.
  void begin(const String& hostname, FrameHandler on_frame);

  /// Persists new credentials and (re)joins. Empty SSID is rejected.
  bool set_credentials(const String& ssid, const String& password);
  /// Drops the network, clears stored credentials, closes any client.
  void forget();

  /// Drives the state machine. Call every loop().
  void service(uint32_t now);

  /// Writes one frame to the connected client, if any.
  void send(const uint8_t* frame, size_t len);

  void mark_authenticated() { client_authenticated_ = true; }
  /// Closes the client socket (after a failed AUTH, or an unauthenticated command).
  void drop_client();

  bool client_connected() { return client_ && client_.connected(); }
  bool client_authenticated() { return client_connected() && client_authenticated_; }
  bool has_credentials() const { return ssid_.length() > 0; }

  proto::WifiState state() const { return state_; }
  IPAddress ip() const { return state_ == proto::WifiState::connected ? WiFi.localIP() : IPAddress(); }
  int8_t rssi() const { return state_ == proto::WifiState::connected ? static_cast<int8_t>(WiFi.RSSI()) : 0; }
  const String& ssid() const { return ssid_; }
  const String& hostname() const { return hostname_; }

  /// Appends one page of scan results to `fb` (already begun as a wifi_scan response
  /// with status ok). Returns `scanning` if results aren't ready yet, in which case the
  /// caller should send that status instead; a page-0 request starts a fresh scan when
  /// the cached results are stale.
  proto::Status scan_page(uint8_t page, proto::FrameBuilder& fb, uint32_t now);

  /// True once per state change so the sketch can broadcast a wifi_changed event.
  bool take_state_changed() { const bool c = state_changed_; state_changed_ = false; return c; }

 private:
  void load_credentials();
  /// Brings the Wi‑Fi driver up on first need. It costs ~50 KB of RAM, so a board
  /// that is Bluetooth-only never pays for it.
  void ensure_stack();
  void start_join(uint32_t now);
  void set_state(proto::WifiState s);
  void on_connected();
  void service_client(uint32_t now);

  String hostname_;
  String ssid_;
  String password_;
  FrameHandler on_frame_;

  proto::WifiState state_ = proto::WifiState::off;
  bool state_changed_ = false;
  uint32_t join_started_ms_ = 0;
  uint32_t next_retry_ms_ = 0;
  bool stack_started_ = false;
  bool server_started_ = false;
  bool mdns_started_ = false;
  uint32_t scan_started_ms_ = 0;
  bool scan_running_ = false;

  WiFiServer server_{proto::tcp_port};
  WiFiClient client_;
  bool client_authenticated_ = false;
  uint32_t client_connected_ms_ = 0;
  uint32_t client_last_rx_ms_ = 0;
  proto::StreamParser parser_;
};

}  // namespace jarvis

#endif  // JARVIS_ESP32_WIFI_LINK_H
