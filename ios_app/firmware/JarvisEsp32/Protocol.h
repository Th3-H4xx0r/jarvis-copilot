// Wire protocol between JarvisWearables and the board. Mirrored byte-for-byte in
// `JarvisWearables/Esp32Protocol.swift`; change both or neither.
//
// The same frames travel over two transports:
//   BLE   one GATT service, two characteristics — the app writes a request to
//         `command`, the board notifies responses and events on `event`.
//   TCP   a raw socket on `tcp_port`.
//
// Ownership: a freshly flashed board is unclaimed. The first phone to connect over BLE
// mints a random 16-byte owner key and sends CLAIM; the board stores it in NVS. From
// then on every session — BLE or TCP — must open with AUTH carrying that key or every
// other opcode answers `unauthorized`. The key never leaves the board. Reflashing
// (any build with a different build stamp) wipes the claim and the Wi‑Fi credentials.
//
// Frame:   A5 | LEN | OP | PAYLOAD… | CRC
//   LEN     number of bytes in OP + PAYLOAD (1…max_body)
//   CRC     CRC-8 (poly 0x07, init 0x00) over LEN, OP and PAYLOAD
// Responses reuse the request opcode with bit 7 set and start their payload with a
// status byte. Events use opcodes 0xE0–0xEF and carry no status.
#ifndef JARVIS_ESP32_PROTOCOL_H
#define JARVIS_ESP32_PROTOCOL_H

#include <stdint.h>
#include <stddef.h>

namespace jarvis::proto {

constexpr uint8_t version = 3;

// "4A6172766973" is "Jarvis" in ASCII, so the service is recognisable in a sniffer.
constexpr const char* service_uuid = "F0E1D2C3-0001-4A56-8000-4A6172766973";
constexpr const char* command_uuid = "F0E1D2C3-0002-4A56-8000-4A6172766973";
constexpr const char* event_uuid   = "F0E1D2C3-0003-4A56-8000-4A6172766973";

constexpr uint16_t tcp_port = 4711;
constexpr const char* mdns_service = "jarvis-esp32";  // advertised as _jarvis-esp32._tcp

constexpr uint8_t sync = 0xA5;
constexpr uint8_t response_bit = 0x80;

constexpr size_t token_len = 16;
constexpr size_t max_ssid_len = 32;
constexpr size_t max_password_len = 64;

// Longest frame either side builds. Sized to the BLE MTU the app negotiates (247 →
// 244 bytes of ATT payload) so script chunks and Jarvis calls get a useful payload.
constexpr size_t max_body = 240;
constexpr size_t max_frame = 3 + max_body;   // sync, len, …body…, crc
constexpr size_t header_size = 3;            // sync + len + op

enum class Op : uint8_t {
  ping        = 0x01,  // → status, proto, fw_major, fw_minor, uptime_s (u32 BE), mac[6], claimed
  get_info    = 0x02,  // → status, pin_count, (gpio, flags)…
  get_state   = 0x03,  // → status, pin_count, (gpio, mode, value)…
  led_set     = 0x10,  // level (0 off, 1 on, 2 toggle)        → status, level
  led_blink   = 0x11,  // count (0 = stop), period_ms (u16 BE)  → status
  pin_mode    = 0x20,  // gpio, mode                            → status
  pin_write   = 0x21,  // gpio, level                           → status, level
  pin_read    = 0x22,  // gpio                                  → status, level
  pin_pwm     = 0x23,  // gpio, duty (0…255)                    → status
  pin_pulse   = 0x24,  // gpio, level, duration_ms (u16 BE)     → status
  all_off     = 0x2F,  // → status. Every output low, PWM/blink/pulse cancelled.
  wifi_set    = 0x40,  // ssid_len, ssid…, pass_len, pass…      → status   (BLE only)
  wifi_status = 0x41,  // → status, state, ip[4], rssi (i8), port (u16 BE),
                       //   host_len, host…, ssid_len, ssid…
  wifi_forget = 0x42,  // → status                              (BLE only)
  auth        = 0x44,  // key[16]                               → status
  claim       = 0x45,  // key[16]                               → status   (BLE only, unclaimed board)
  cloud_set   = 0x48,  // url_len, url…, code_len, code…, cfid_len, cfid…, cfsec_len, cfsec…
                       //   → status. Board pairs with JarvisCopilot over Wi‑Fi, stores the
                       //   session, then reboots into cloud mode (BLE off, bridge WS on).
  cloud_status = 0x49, // → status, state, mode, url_len, url…, err_len, err…
  cloud_forget = 0x4A, // → status. Drops the session and reboots into Bluetooth mode.
  cloud_pause  = 0x4B, // → status. Keeps the session, reboots into Bluetooth mode for now.
  reset_owner = 0x47,  // → status. Forgets the owner key so the next phone can claim the
                       //   board — ONLY while the BOOT button is held (physical presence),
                       //   so a stranger over BLE cannot steal a board. Any link may send it.
  wifi_scan   = 0x46,  // page                                  → status, total, page, count,
                       //   (rssi (i8), secure, ssid_len, ssid…)… — or `scanning`, retry
  // Script runtime. Upload = BEGIN, CHUNK…, COMMIT. The stored script autostarts at boot.
  script_begin  = 0x50,  // total_len (u16 BE), autostart, name_len, name…   → status
  script_chunk  = 0x51,  // offset (u16 BE), bytes…                          → status
  script_commit = 0x52,  // crc8 of the whole source                          → status (script_error + message on compile failure)
  script_stop   = 0x53,  // → status
  script_start  = 0x54,  // → status (runs the stored script)
  script_status = 0x55,  // → status, state, autostart, size (u16), name_len, name…, err_len, err…
  script_delete = 0x56,  // → status
  jarvis_result = 0x57,  // call_id (u16 BE), ok, text…  (reply to a jarvis_call event) → status
};

enum class ScriptState : uint8_t {
  none     = 0,  // nothing stored
  stopped  = 1,  // stored, not running
  running  = 2,
  finished = 3,  // ran to completion with no callbacks left
  error    = 4,  // compile or runtime error; see message
};

enum class Event : uint8_t {
  input_changed = 0xE1,  // gpio, level
  pulse_done    = 0xE2,  // gpio, level (the level it returned to)
  blink_done    = 0xE3,  // (none)
  wifi_changed  = 0xE4,  // state, ip[4]
  script_output = 0xE5,  // text (a print() line, or an error)
  jarvis_call   = 0xE6,  // call_id (u16 BE), name_len, name…, json args…
  script_state  = 0xE7,  // state (ScriptState)
  cloud_changed = 0xE8,  // state (CloudState)
};

enum class CloudState : uint8_t {
  off        = 0,  // not paired with a server
  paired     = 1,  // session stored, board is in Bluetooth mode (link not active)
  connecting = 2,
  connected  = 3,  // bridge WebSocket up, skills registered
  failed     = 4,  // see message; retrying
  expired    = 5,  // server rejected the session; pair again
};

enum class Status : uint8_t {
  ok             = 0x00,
  bad_frame      = 0x01,  // sync, length or CRC wrong
  unknown_op     = 0x02,
  bad_pin        = 0x03,  // GPIO is not in the exposed table
  bad_arg        = 0x04,  // value out of range or wrong payload length
  not_capable    = 0x05,  // pin can't do that (e.g. write to an input-only pin)
  busy           = 0x06,  // a pulse is already running on that pin
  unauthorized   = 0x07,  // session has not sent a valid AUTH (or board is unclaimed)
  wrong_link     = 0x08,  // this opcode is only allowed on the other transport
  already_claimed = 0x09, // CLAIM on a board that already has an owner
  scanning       = 0x0A,  // Wi‑Fi scan in progress; ask again in a second
  script_error   = 0x0B,  // payload carries the message
};

// Networks per WIFI_SCAN page: 3 × (1 + 1 + 1 + 32) + 3 header bytes fits max_body.
constexpr uint8_t scan_page_size = 3;

// Pin mode as reported in GET_STATE and accepted by PIN_MODE.
enum class Mode : uint8_t {
  unset          = 0,  // never configured since boot; reads as input
  output         = 1,
  input          = 2,
  input_pullup   = 3,
  input_pulldown = 4,
  pwm            = 5,
};

enum class WifiState : uint8_t {
  off        = 0,  // no credentials stored
  connecting = 1,
  connected  = 2,
  failed     = 3,  // credentials stored but the join failed; retries periodically
};

constexpr uint8_t crc8_poly = 0x07;

constexpr uint8_t crc8(const uint8_t* data, size_t len) {
  uint8_t crc = 0;
  for (size_t i = 0; i < len; ++i) {
    crc ^= data[i];
    for (int bit = 0; bit < 8; ++bit) {
      crc = (crc & 0x80) ? static_cast<uint8_t>((crc << 1) ^ crc8_poly)
                         : static_cast<uint8_t>(crc << 1);
    }
  }
  return crc;
}

/// A decoded request. `payload` points into the caller's buffer.
struct Request {
  uint8_t op;
  const uint8_t* payload;
  size_t payload_len;
};

/// Validates framing and CRC. Returns bad_frame on any structural problem so the
/// caller can answer with a generic error frame (opcode 0x80) instead of guessing.
inline Status decode(const uint8_t* buf, size_t len, Request& out) {
  if (len < header_size + 1) return Status::bad_frame;
  if (buf[0] != sync) return Status::bad_frame;
  const size_t body_len = buf[1];
  if (body_len < 1 || body_len > max_body) return Status::bad_frame;
  if (len != 2 + body_len + 1) return Status::bad_frame;
  if (crc8(buf + 1, 1 + body_len) != buf[len - 1]) return Status::bad_frame;
  out.op = buf[2];
  out.payload = buf + 3;
  out.payload_len = body_len - 1;
  return Status::ok;
}

/// Fixed-capacity frame builder. Drops bytes past capacity and makes `finish()`
/// return 0, so a truncated frame is never sent.
class FrameBuilder {
 public:
  FrameBuilder() = default;

  void begin(uint8_t op) {
    len_ = 0;
    overflow_ = false;
    push(sync);
    push(0);  // length, patched in finish()
    push(op);
  }
  void begin_response(Op op, Status status) {
    begin(static_cast<uint8_t>(op) | response_bit);
    push(static_cast<uint8_t>(status));
  }
  void begin_event(Event ev) { begin(static_cast<uint8_t>(ev)); }

  void push(uint8_t b) {
    if (len_ >= max_frame - 1) { overflow_ = true; return; }  // keep room for the CRC
    buf_[len_++] = b;
  }
  void push_u16(uint16_t v) { push(static_cast<uint8_t>(v >> 8)); push(static_cast<uint8_t>(v)); }
  void push_u32(uint32_t v) { push_u16(static_cast<uint16_t>(v >> 16)); push_u16(static_cast<uint16_t>(v)); }
  void push_bytes(const uint8_t* p, size_t n) { for (size_t i = 0; i < n; ++i) push(p[i]); }
  /// Length-prefixed string, clamped to `max`.
  void push_string(const char* s, size_t max) {
    size_t n = 0;
    while (s[n] != '\0' && n < max) ++n;
    push(static_cast<uint8_t>(n));
    push_bytes(reinterpret_cast<const uint8_t*>(s), n);
  }

  /// Patches the length and appends the CRC. Returns the finished frame size, or 0
  /// if the frame overflowed.
  size_t finish() {
    if (overflow_ || len_ < header_size) return 0;
    buf_[1] = static_cast<uint8_t>(len_ - 2);
    buf_[len_++] = crc8(buf_ + 1, len_ - 1);
    return len_;
  }

  const uint8_t* data() const { return buf_; }
  size_t size() const { return len_; }

 private:
  uint8_t buf_[max_frame] = {};
  size_t len_ = 0;
  bool overflow_ = false;
};

/// Reassembles frames from a byte stream (the TCP side). Garbage before a sync byte
/// is skipped; an over-long or corrupt frame is dropped and parsing resynchronises.
class StreamParser {
 public:
  /// Feed one byte. Returns true when `frame()`/`frame_len()` hold a complete,
  /// structurally valid frame. The frame stays valid until the next call.
  bool feed(uint8_t b) {
    if (len_ == 0) {
      if (b != sync) return false;
      buf_[len_++] = b;
      return false;
    }
    if (len_ == 1) {
      if (b < 1 || b > max_body) { len_ = 0; return false; }
      buf_[len_++] = b;
      return false;
    }
    buf_[len_++] = b;
    const size_t expected = 2 + buf_[1] + 1;
    if (len_ < expected) return false;
    complete_len_ = len_;
    len_ = 0;
    return true;
  }
  const uint8_t* frame() const { return buf_; }
  size_t frame_len() const { return complete_len_; }
  void reset() { len_ = 0; }

 private:
  uint8_t buf_[max_frame] = {};
  size_t len_ = 0;
  size_t complete_len_ = 0;
};

// Compile-time known-answer test for CRC-8 poly 0x07 ("123456789" → 0xF4).
namespace self_test {
constexpr uint8_t kat[] = {'1', '2', '3', '4', '5', '6', '7', '8', '9'};
static_assert(crc8(kat, sizeof(kat)) == 0xF4, "CRC-8 poly 0x07 known answer");
static_assert(crc8(nullptr, 0) == 0, "empty CRC is zero");
static_assert(1 + 1 + max_ssid_len + 1 + max_password_len <= max_body, "WIFI_SET must fit");
}  // namespace self_test

}  // namespace jarvis::proto

#endif  // JARVIS_ESP32_PROTOCOL_H
