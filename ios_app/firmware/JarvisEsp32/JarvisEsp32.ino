// Jarvis ESP32 — BLE + Wi‑Fi GPIO peripheral for JarvisWearables.
//
// Target: DOIT ESP32 DEVKIT V1, Arduino-ESP32 core 3.x (Bluedroid BLE stack).
// Build with the "Huge APP" partition scheme — BLE and Wi‑Fi together do not fit in
// the default 1.3 MB app slot. `flash.sh` sets this up.
//
// The board advertises one encrypted GATT service. The first phone to connect claims
// the board with a random owner key; afterwards every session must AUTH with that key
// before it can drive the onboard LED and GPIOs through framed, CRC-checked commands
// (see Protocol.h). Over BLE the owner can also hand the board Wi‑Fi credentials, after
// which the same command set is reachable over a TCP socket on the LAN.
//
// Threading: BLE callbacks run on the Bluetooth task. They never touch pin state —
// incoming frames are copied into a FreeRTOS queue and everything else (decode, GPIO,
// Wi‑Fi, notify) happens in loop(). That keeps the GPIO state machine single-threaded.

#include <Arduino.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <BLESecurity.h>
#include <Preferences.h>
#include <esp_mac.h>
#include <esp32-hal-bt.h>

#include "Config.h"
#include "Pins.h"
#include "Protocol.h"
#include "WifiLink.h"
#include "ScriptRuntime.h"
#include "CloudLink.h"

namespace cfg = jarvis::config;
namespace pins = jarvis::pins;
namespace proto = jarvis::proto;

// ───────────────────────────── State ─────────────────────────────

struct PinState {
  proto::Mode mode = proto::Mode::unset;
  uint8_t value = 0;             // last driven level, or PWM duty
  bool pulse_active = false;
  uint8_t pulse_return_level = 0;
  uint32_t pulse_deadline_ms = 0;
  // Debounce for change events (input modes only).
  uint8_t stable_level = 0;
  uint8_t candidate_level = 0;
  uint32_t candidate_since_ms = 0;
};

struct BlinkState {
  bool active = false;
  uint16_t toggles_left = 0;     // 2 per blink
  uint16_t period_ms = 0;
  uint32_t next_toggle_ms = 0;
};

struct IncomingFrame {
  uint8_t len;
  uint8_t bytes[proto::max_frame];
};

// Which transport a request arrived on; its response goes back the same way. A running
// script and the cloud bridge are internal clients with the same command set.
enum class Link : uint8_t { ble, tcp, script, cloud };

namespace {

PinState g_pins[pins::count];
BlinkState g_blink;
jarvis::WifiLink g_wifi;
jarvis::ScriptRuntime g_script;
jarvis::CloudLink g_cloud;
bool g_cloud_boot = false;   // booted without Bluetooth, holding the bridge instead

// Reply capture for commands the cloud bridge runs through dispatch().
struct CapturedFrame { uint8_t len; uint8_t bytes[proto::max_frame]; };
CapturedFrame g_cloud_reply;

// Last script console lines, for esp32_script_status over the bridge.
constexpr size_t log_lines = 16;
String g_log[log_lines];
size_t g_log_head = 0, g_log_count = 0;
portMUX_TYPE g_log_mux = portMUX_INITIALIZER_UNLOCKED;

bool g_pairing_boot = false;        // this boot exists only to pair with the server
uint32_t g_pairing_boot_started = 0;
// In Bluetooth mode: how long the board has had Wi‑Fi, a Jarvis session and no phone.
uint32_t g_unattended_since_ms = 0;
uint32_t g_auto_cloud_delay_ms = 60000;

constexpr uint8_t boot_button_gpio = 0;
constexpr uint32_t boot_button_hold_ms = 3000;
uint32_t g_boot_pressed_ms = 0;
uint8_t g_owner_key[proto::token_len] = {};
bool g_claimed = false;
uint8_t g_mac[6] = {};

BLEServer* g_server = nullptr;
BLECharacteristic* g_event_char = nullptr;
QueueHandle_t g_rx_queue = nullptr;

// Written from the BT task, read in loop(). Single-word writes are atomic on ESP32.
volatile bool g_ble_connected = false;
volatile bool g_ble_authenticated = false;  // link-layer pairing done
bool g_ble_authorized = false;              // this BLE session presented the owner key
volatile uint16_t g_conn_id = 0;
volatile uint32_t g_dropped_frames = 0;

Link g_reply_link = Link::ble;
uint32_t g_last_input_poll_ms = 0;
uint32_t g_last_link_blink_ms = 0;
bool g_link_led_level = false;

constexpr uint8_t rx_queue_depth = 4;
constexpr uint32_t link_blink_period_ms = 1000;
constexpr const char* prefs_namespace = "jarvis";
constexpr const char* key_owner = "owner";
constexpr const char* key_build = "build";
// Changes with every compile, so a reflash — from this script or the IDE — wipes the
// claim and the Wi‑Fi credentials. Same-binary reboots keep them.
constexpr const char* build_stamp = __DATE__ " " __TIME__;

// ───────────────────────────── GPIO helpers ─────────────────────────────

const pins::Pin& pin_def(int index) { return pins::table[index]; }

bool is_input_mode(proto::Mode m) {
  return m == proto::Mode::input || m == proto::Mode::input_pullup || m == proto::Mode::input_pulldown;
}

void leave_pwm(int index) {
  if (g_pins[index].mode == proto::Mode::pwm) {
    ledcDetach(pin_def(index).gpio);
  }
}

// Puts a pin in a mode. Returns false when the pin can't do it.
bool apply_mode(int index, proto::Mode mode) {
  const pins::Pin& p = pin_def(index);
  PinState& s = g_pins[index];
  switch (mode) {
    case proto::Mode::output:
      if (!pins::has(p.flags, pins::Capability::output)) return false;
      leave_pwm(index);
      pinMode(p.gpio, OUTPUT);
      digitalWrite(p.gpio, s.mode == proto::Mode::output ? s.value : LOW);
      if (s.mode != proto::Mode::output) s.value = 0;
      break;
    case proto::Mode::input:
      leave_pwm(index);
      pinMode(p.gpio, INPUT);
      break;
    case proto::Mode::input_pullup:
      // GPIO 34–39 have no internal pull resistors.
      if (!pins::has(p.flags, pins::Capability::output)) return false;
      leave_pwm(index);
      pinMode(p.gpio, INPUT_PULLUP);
      break;
    case proto::Mode::input_pulldown:
      if (!pins::has(p.flags, pins::Capability::output)) return false;
      leave_pwm(index);
      pinMode(p.gpio, INPUT_PULLDOWN);
      break;
    case proto::Mode::pwm:
      if (!pins::has(p.flags, pins::Capability::pwm)) return false;
      // analogWrite attaches the LEDC channel on first use.
      break;
    case proto::Mode::unset:
      return false;
  }
  s.pulse_active = false;
  s.mode = mode;
  if (is_input_mode(mode)) {
    s.stable_level = s.candidate_level = digitalRead(p.gpio);
    s.candidate_since_ms = millis();
    s.value = s.stable_level;
  }
  return true;
}

bool write_level(int index, uint8_t level) {
  if (g_pins[index].mode != proto::Mode::output) {
    if (!apply_mode(index, proto::Mode::output)) return false;
  }
  g_pins[index].value = level ? 1 : 0;
  digitalWrite(pin_def(index).gpio, g_pins[index].value);
  return true;
}

uint8_t read_level(int index) {
  const PinState& s = g_pins[index];
  if (s.mode == proto::Mode::output) return s.value;
  if (s.mode == proto::Mode::pwm) return s.value > 0;
  return digitalRead(pin_def(index).gpio) ? 1 : 0;
}

void cancel_blink() { g_blink = BlinkState{}; }

void all_off() {
  cancel_blink();
  for (size_t i = 0; i < pins::count; ++i) {
    PinState& s = g_pins[i];
    s.pulse_active = false;
    if (s.mode == proto::Mode::output || s.mode == proto::Mode::pwm) {
      leave_pwm(static_cast<int>(i));
      s.mode = proto::Mode::output;
      s.value = 0;
      pinMode(pin_def(static_cast<int>(i)).gpio, OUTPUT);
      digitalWrite(pin_def(static_cast<int>(i)).gpio, LOW);
    }
  }
}

// ───────────────────────────── Sending ─────────────────────────────

void send_ble(const uint8_t* data, size_t n) {
  if (!g_ble_connected || g_event_char == nullptr) return;
  // setValue copies; the builder can be reused immediately after.
  g_event_char->setValue(const_cast<uint8_t*>(data), n);
  g_event_char->notify();
}

/// Response to the request currently being handled — back on the link it came from.
void send_frame(proto::FrameBuilder& fb) {
  const size_t n = fb.finish();
  if (n == 0) {
    Serial.println("[tx] frame overflow, dropped");
    return;
  }
  switch (g_reply_link) {
    case Link::tcp:    g_wifi.send(fb.data(), n); break;
    case Link::script: g_script.deliver_reply(fb.data(), n); break;
    case Link::cloud:  g_cloud_reply.len = static_cast<uint8_t>(n); memcpy(g_cloud_reply.bytes, fb.data(), n); break;
    case Link::ble:    send_ble(fb.data(), n); break;
  }
}

/// Unsolicited event — every live, authenticated link and the running script get a copy.
void broadcast_raw(const uint8_t* data, size_t n) {
  send_ble(data, n);
  if (g_wifi.client_authenticated()) g_wifi.send(data, n);
  g_script.deliver_event(data, n);
}

void broadcast_event(proto::FrameBuilder& fb) {
  const size_t n = fb.finish();
  if (n == 0) return;
  broadcast_raw(fb.data(), n);
}

void send_status(proto::Op op, proto::Status st) {
  proto::FrameBuilder fb;
  fb.begin_response(op, st);
  send_frame(fb);
}

void send_status_level(proto::Op op, proto::Status st, uint8_t level) {
  proto::FrameBuilder fb;
  fb.begin_response(op, st);
  fb.push(level);
  send_frame(fb);
}

void send_wifi_changed() {
  proto::FrameBuilder fb;
  fb.begin_event(proto::Event::wifi_changed);
  fb.push(static_cast<uint8_t>(g_wifi.state()));
  const IPAddress ip = g_wifi.ip();
  for (int i = 0; i < 4; ++i) fb.push(ip[i]);
  broadcast_event(fb);
}

// ───────────────────────────── Command handlers ─────────────────────────────

// Resolves payload[0] to a table index, answering bad_pin itself on failure.
bool resolve_pin(proto::Op op, const proto::Request& r, size_t min_len, int& index) {
  if (r.payload_len < min_len) { send_status(op, proto::Status::bad_arg); return false; }
  index = pins::index_of(r.payload[0]);
  if (index < 0) { send_status(op, proto::Status::bad_pin); return false; }
  return true;
}

uint16_t read_u16(const uint8_t* p) { return static_cast<uint16_t>((p[0] << 8) | p[1]); }

void handle_ping(const proto::Request&) {
  proto::FrameBuilder fb;
  fb.begin_response(proto::Op::ping, proto::Status::ok);
  fb.push(proto::version);
  fb.push(cfg::firmware_major);
  fb.push(cfg::firmware_minor);
  fb.push_u32(millis() / 1000);
  fb.push_bytes(g_mac, sizeof(g_mac));
  fb.push(g_claimed ? 1 : 0);
  send_frame(fb);
}

void handle_get_info(const proto::Request&) {
  proto::FrameBuilder fb;
  fb.begin_response(proto::Op::get_info, proto::Status::ok);
  fb.push(static_cast<uint8_t>(pins::count));
  for (size_t i = 0; i < pins::count; ++i) {
    fb.push(pins::table[i].gpio);
    fb.push(pins::table[i].flags);
  }
  send_frame(fb);
}

void handle_get_state(const proto::Request&) {
  proto::FrameBuilder fb;
  fb.begin_response(proto::Op::get_state, proto::Status::ok);
  fb.push(static_cast<uint8_t>(pins::count));
  for (size_t i = 0; i < pins::count; ++i) {
    const PinState& s = g_pins[i];
    fb.push(pins::table[i].gpio);
    fb.push(static_cast<uint8_t>(s.mode));
    fb.push(s.mode == proto::Mode::pwm ? s.value : read_level(static_cast<int>(i)));
  }
  send_frame(fb);
}

void handle_led_set(const proto::Request& r) {
  constexpr proto::Op op = proto::Op::led_set;
  if (r.payload_len < 1 || r.payload[0] > 2) { send_status(op, proto::Status::bad_arg); return; }
  const int index = pins::index_of(pins::onboard_led_gpio);
  cancel_blink();
  const uint8_t level = r.payload[0] == 2 ? !read_level(index) : r.payload[0];
  if (!write_level(index, level)) { send_status(op, proto::Status::not_capable); return; }
  send_status_level(op, proto::Status::ok, g_pins[index].value);
}

void handle_led_blink(const proto::Request& r) {
  constexpr proto::Op op = proto::Op::led_blink;
  if (r.payload_len < 3) { send_status(op, proto::Status::bad_arg); return; }
  const uint8_t count = r.payload[0];
  const uint16_t period = read_u16(r.payload + 1);
  if (count == 0) {
    cancel_blink();
    write_level(pins::index_of(pins::onboard_led_gpio), 0);
    send_status(op, proto::Status::ok);
    return;
  }
  if (period < cfg::min_blink_period_ms || period > cfg::max_blink_period_ms) {
    send_status(op, proto::Status::bad_arg);
    return;
  }
  const int index = pins::index_of(pins::onboard_led_gpio);
  if (!write_level(index, 1)) { send_status(op, proto::Status::not_capable); return; }
  g_blink.active = true;
  g_blink.toggles_left = static_cast<uint16_t>(count * 2 - 1);
  g_blink.period_ms = period;
  g_blink.next_toggle_ms = millis() + period / 2;
  send_status(op, proto::Status::ok);
}

void handle_pin_mode(const proto::Request& r) {
  constexpr proto::Op op = proto::Op::pin_mode;
  int index;
  if (!resolve_pin(op, r, 2, index)) return;
  const uint8_t raw = r.payload[1];
  if (raw < 1 || raw > 5) { send_status(op, proto::Status::bad_arg); return; }
  if (!apply_mode(index, static_cast<proto::Mode>(raw))) { send_status(op, proto::Status::not_capable); return; }
  send_status(op, proto::Status::ok);
}

void handle_pin_write(const proto::Request& r) {
  constexpr proto::Op op = proto::Op::pin_write;
  int index;
  if (!resolve_pin(op, r, 2, index)) return;
  if (r.payload[1] > 1) { send_status(op, proto::Status::bad_arg); return; }
  if (g_pins[index].pulse_active) { send_status(op, proto::Status::busy); return; }
  if (pin_def(index).gpio == pins::onboard_led_gpio) cancel_blink();
  if (!write_level(index, r.payload[1])) { send_status(op, proto::Status::not_capable); return; }
  send_status_level(op, proto::Status::ok, g_pins[index].value);
}

void handle_pin_read(const proto::Request& r) {
  constexpr proto::Op op = proto::Op::pin_read;
  int index;
  if (!resolve_pin(op, r, 1, index)) return;
  send_status_level(op, proto::Status::ok, read_level(index));
}

void handle_pin_pwm(const proto::Request& r) {
  constexpr proto::Op op = proto::Op::pin_pwm;
  int index;
  if (!resolve_pin(op, r, 2, index)) return;
  if (g_pins[index].pulse_active) { send_status(op, proto::Status::busy); return; }
  if (!apply_mode(index, proto::Mode::pwm)) { send_status(op, proto::Status::not_capable); return; }
  if (pin_def(index).gpio == pins::onboard_led_gpio) cancel_blink();
  g_pins[index].value = r.payload[1];
  analogWrite(pin_def(index).gpio, r.payload[1]);
  send_status(op, proto::Status::ok);
}

void handle_pin_pulse(const proto::Request& r) {
  constexpr proto::Op op = proto::Op::pin_pulse;
  int index;
  if (!resolve_pin(op, r, 4, index)) return;
  const uint8_t level = r.payload[1];
  const uint16_t duration = read_u16(r.payload + 2);
  if (level > 1 || duration == 0 || duration > cfg::max_pulse_ms) { send_status(op, proto::Status::bad_arg); return; }
  if (g_pins[index].pulse_active) { send_status(op, proto::Status::busy); return; }
  if (pin_def(index).gpio == pins::onboard_led_gpio) cancel_blink();
  if (!write_level(index, level)) { send_status(op, proto::Status::not_capable); return; }
  PinState& s = g_pins[index];
  s.pulse_active = true;
  s.pulse_return_level = !level;
  s.pulse_deadline_ms = millis() + duration;
  send_status(op, proto::Status::ok);
}

void handle_all_off(const proto::Request&) {
  all_off();
  send_status(proto::Op::all_off, proto::Status::ok);
}

// Wi‑Fi credentials and the access token only ever travel over the bonded BLE link.
bool require_ble(proto::Op op) {
  if (g_reply_link == Link::ble) return true;
  send_status(op, proto::Status::wrong_link);
  return false;
}

void handle_wifi_set(const proto::Request& r) {
  constexpr proto::Op op = proto::Op::wifi_set;
  if (!require_ble(op)) return;
  // ssid_len, ssid…, pass_len, pass…
  if (r.payload_len < 2) { send_status(op, proto::Status::bad_arg); return; }
  const size_t ssid_len = r.payload[0];
  if (ssid_len == 0 || ssid_len > proto::max_ssid_len || 1 + ssid_len + 1 > r.payload_len) {
    send_status(op, proto::Status::bad_arg);
    return;
  }
  const size_t pass_len = r.payload[1 + ssid_len];
  if (pass_len > proto::max_password_len || 1 + ssid_len + 1 + pass_len != r.payload_len) {
    send_status(op, proto::Status::bad_arg);
    return;
  }
  String ssid, password;
  ssid.reserve(ssid_len);
  password.reserve(pass_len);
  for (size_t i = 0; i < ssid_len; ++i) ssid += static_cast<char>(r.payload[1 + i]);
  for (size_t i = 0; i < pass_len; ++i) password += static_cast<char>(r.payload[2 + ssid_len + i]);
  if (!g_wifi.set_credentials(ssid, password)) { send_status(op, proto::Status::bad_arg); return; }
  send_status(op, proto::Status::ok);
}

void handle_wifi_status(const proto::Request&) {
  proto::FrameBuilder fb;
  fb.begin_response(proto::Op::wifi_status, proto::Status::ok);
  fb.push(static_cast<uint8_t>(g_wifi.state()));
  const IPAddress ip = g_wifi.ip();
  for (int i = 0; i < 4; ++i) fb.push(ip[i]);
  fb.push(static_cast<uint8_t>(g_wifi.rssi()));
  fb.push_u16(proto::tcp_port);
  fb.push_string(g_wifi.hostname().c_str(), 32);
  fb.push_string(g_wifi.ssid().c_str(), proto::max_ssid_len);
  send_frame(fb);
}

void handle_wifi_forget(const proto::Request&) {
  constexpr proto::Op op = proto::Op::wifi_forget;
  if (!require_ble(op)) return;
  g_wifi.forget();
  send_status(op, proto::Status::ok);
}

void handle_wifi_scan(const proto::Request& r) {
  constexpr proto::Op op = proto::Op::wifi_scan;
  const uint8_t page = r.payload_len >= 1 ? r.payload[0] : 0;
  proto::FrameBuilder fb;
  fb.begin_response(op, proto::Status::ok);
  const proto::Status st = g_wifi.scan_page(page, fb, millis());
  if (st != proto::Status::ok) { send_status(op, st); return; }
  send_frame(fb);
}

// ── Script runtime ──

void send_script_error(proto::Op op, const String& message) {
  proto::FrameBuilder fb;
  fb.begin_response(op, proto::Status::script_error);
  fb.push_bytes(reinterpret_cast<const uint8_t*>(message.c_str()),
                message.length() > proto::max_body - 2 ? proto::max_body - 2 : message.length());
  send_frame(fb);
}

void handle_script_begin(const proto::Request& r) {
  constexpr proto::Op op = proto::Op::script_begin;
  // total (u16), autostart, name_len, name…
  if (r.payload_len < 4) { send_status(op, proto::Status::bad_arg); return; }
  const uint16_t total = read_u16(r.payload);
  const bool autostart = r.payload[2] != 0;
  const size_t name_len = r.payload[3];
  if (4 + name_len > r.payload_len) { send_status(op, proto::Status::bad_arg); return; }
  String name;
  for (size_t i = 0; i < name_len; ++i) name += static_cast<char>(r.payload[4 + i]);
  if (!g_script.upload_begin(total, autostart, name)) { send_status(op, proto::Status::bad_arg); return; }
  send_status(op, proto::Status::ok);
}

void handle_script_chunk(const proto::Request& r) {
  constexpr proto::Op op = proto::Op::script_chunk;
  if (r.payload_len < 3) { send_status(op, proto::Status::bad_arg); return; }
  if (!g_script.upload_chunk(read_u16(r.payload), r.payload + 2, r.payload_len - 2)) {
    send_status(op, proto::Status::bad_arg);
    return;
  }
  send_status(op, proto::Status::ok);
}

void handle_script_commit(const proto::Request& r) {
  constexpr proto::Op op = proto::Op::script_commit;
  if (r.payload_len < 1) { send_status(op, proto::Status::bad_arg); return; }
  String message;
  if (!g_script.upload_commit(r.payload[0], message)) { send_script_error(op, message); return; }
  send_status(op, proto::Status::ok);
}

void handle_script_start(const proto::Request&) {
  String message;
  if (!g_script.start(message)) { send_script_error(proto::Op::script_start, message); return; }
  send_status(proto::Op::script_start, proto::Status::ok);
}

void handle_script_status(const proto::Request&) {
  proto::FrameBuilder fb;
  fb.begin_response(proto::Op::script_status, proto::Status::ok);
  fb.push(static_cast<uint8_t>(g_script.state()));
  fb.push(g_script.autostart() ? 1 : 0);
  fb.push_u16(g_script.size());
  fb.push_string(g_script.name().c_str(), 40);
  fb.push_string(g_script.last_error().c_str(), 160);
  send_frame(fb);
}

// The phone's answer to a jarvis_call event: forwarded to the script as an event.
void handle_jarvis_result(const proto::Request& r) {
  constexpr proto::Op op = proto::Op::jarvis_result;
  if (r.payload_len < 3) { send_status(op, proto::Status::bad_arg); return; }
  proto::FrameBuilder fb;
  fb.begin(static_cast<uint8_t>(op));
  fb.push_bytes(r.payload, r.payload_len);
  const size_t n = fb.finish();
  if (n) g_script.deliver_event(fb.data(), n);
  send_status(op, proto::Status::ok);
}

// ── Cloud bridge ──

void send_cloud_changed() {
  proto::FrameBuilder fb;
  fb.begin_event(proto::Event::cloud_changed);
  fb.push(static_cast<uint8_t>(g_cloud.state()));
  broadcast_event(fb);
}

void log_push(const String& line) {
  portENTER_CRITICAL(&g_log_mux);
  g_log[g_log_head] = line;
  g_log_head = (g_log_head + 1) % log_lines;
  if (g_log_count < log_lines) ++g_log_count;
  portEXIT_CRITICAL(&g_log_mux);
}

// The catalogue the board advertises on the bridge — the same skills the app
// exposes on its behalf, so Jarvis drives a board the same way either route.
const char skills_json[] PROGMEM = R"JSON([
{"name":"esp32_get_state","description":"Read every exposed GPIO: number, capabilities, current mode and level, plus Wi-Fi, link and script state.","input_schema":{"type":"object","properties":{}}},
{"name":"esp32_set_led","description":"Turn the board's onboard blue LED on or off.","input_schema":{"type":"object","properties":{"on":{"type":"boolean"}},"required":["on"]}},
{"name":"esp32_blink_led","description":"Blink the onboard LED a number of times.","input_schema":{"type":"object","properties":{"count":{"type":"integer","minimum":1,"maximum":255,"default":3},"period_ms":{"type":"integer","minimum":50,"maximum":5000,"default":300}}}},
{"name":"esp32_write_pin","description":"Drive a GPIO high or low. Puts the pin in output mode if it isn't already.","input_schema":{"type":"object","properties":{"gpio":{"type":"integer"},"high":{"type":"boolean"}},"required":["gpio","high"]}},
{"name":"esp32_read_pin","description":"Read the current level of a GPIO.","input_schema":{"type":"object","properties":{"gpio":{"type":"integer"}},"required":["gpio"]}},
{"name":"esp32_set_pin_mode","description":"Configure a GPIO as output, input, input_pullup, input_pulldown or pwm.","input_schema":{"type":"object","properties":{"gpio":{"type":"integer"},"mode":{"type":"string","enum":["output","input","input_pullup","input_pulldown","pwm"]}},"required":["gpio","mode"]}},
{"name":"esp32_set_pwm","description":"Output a PWM signal on a GPIO. Duty 0 is off, 255 is fully on.","input_schema":{"type":"object","properties":{"gpio":{"type":"integer"},"duty":{"type":"integer","minimum":0,"maximum":255}},"required":["gpio","duty"]}},
{"name":"esp32_pulse_pin","description":"Drive a GPIO to a level for a number of milliseconds, then back.","input_schema":{"type":"object","properties":{"gpio":{"type":"integer"},"high":{"type":"boolean","default":true},"duration_ms":{"type":"integer","minimum":1,"maximum":10000,"default":200}},"required":["gpio"]}},
{"name":"esp32_all_off","description":"Set every output low and cancel any PWM, pulse or blink. The safe stop.","input_schema":{"type":"object","properties":{}}},
{"name":"esp32_upload_script","description":"Program the board: upload a Lua script that runs on it (sandboxed, survives reboots). Replaces the current script. See the jarvis-esp32 skill for the API. Returns the compile result.","input_schema":{"type":"object","properties":{"source":{"type":"string","description":"Lua 5.4 source, up to 16 KB"},"name":{"type":"string"},"autostart":{"type":"boolean","default":true}},"required":["source","name"]}},
{"name":"esp32_script_status","description":"State of the script on the board (none/stopped/running/finished/error), its name and last error, plus recent console output.","input_schema":{"type":"object","properties":{"log_lines":{"type":"integer","default":20}}}},
{"name":"esp32_script_control","description":"start, stop or delete the script stored on the board.","input_schema":{"type":"object","properties":{"action":{"type":"string","enum":["start","stop","delete"]}},"required":["action"]}}
])JSON";

void dispatch(const uint8_t* bytes, size_t len, Link link);

// Runs a protocol command on behalf of the bridge and hands back the decoded reply.
bool cloud_exec(proto::Op op, const uint8_t* payload, size_t len, proto::Request& reply, String& error) {
  proto::FrameBuilder fb;
  fb.begin(static_cast<uint8_t>(op));
  fb.push_bytes(payload, len);
  const size_t n = fb.finish();
  if (n == 0) { error = "frame too long"; return false; }
  g_cloud_reply.len = 0;
  dispatch(fb.data(), n, Link::cloud);
  if (g_cloud_reply.len == 0 || proto::decode(g_cloud_reply.bytes, g_cloud_reply.len, reply) != proto::Status::ok ||
      reply.payload_len < 1) {
    error = "no reply";
    return false;
  }
  const proto::Status st = static_cast<proto::Status>(reply.payload[0]);
  if (st == proto::Status::ok) return true;
  switch (st) {
    case proto::Status::bad_pin: error = "that GPIO is not exposed"; break;
    case proto::Status::bad_arg: error = "bad argument"; break;
    case proto::Status::not_capable: error = "pin cannot do that"; break;
    case proto::Status::busy: error = "pin is busy with a pulse"; break;
    case proto::Status::script_error: error = String(reinterpret_cast<const char*>(reply.payload + 1), reply.payload_len - 1); break;
    default: error = "command failed"; break;
  }
  return false;
}

const char* mode_name(proto::Mode m) {
  switch (m) {
    case proto::Mode::output: return "output";
    case proto::Mode::input: return "input";
    case proto::Mode::input_pullup: return "input_pullup";
    case proto::Mode::input_pulldown: return "input_pulldown";
    case proto::Mode::pwm: return "pwm";
    default: return "unset";
  }
}

const char* script_state_name(proto::ScriptState s) {
  switch (s) {
    case proto::ScriptState::stopped: return "stopped";
    case proto::ScriptState::running: return "running";
    case proto::ScriptState::finished: return "finished";
    case proto::ScriptState::error: return "error";
    default: return "none";
  }
}

void fill_script_status(JsonObject out) {
  out["state"] = script_state_name(g_script.state());
  out["name"] = g_script.name();
  out["size"] = g_script.size();
  out["autostart"] = g_script.autostart();
  out["error"] = g_script.last_error();
}

bool run_skill(const char* skill, JsonVariantConst args, JsonDocument& result, String& error) {
  proto::Request reply{};
  const String name = skill;
  auto gpio_arg = [&](uint8_t& gpio) -> bool {
    const int g = args["gpio"] | -1;
    if (g < 0 || g > 255 || pins::index_of(static_cast<uint8_t>(g)) < 0) { error = "gpio is not exposed"; return false; }
    gpio = static_cast<uint8_t>(g);
    return true;
  };

  if (name == "esp32_get_state") {
    result["connected"] = true;
    result["link"] = "cloud";
    result["led_on"] = read_level(pins::index_of(pins::onboard_led_gpio)) != 0;
    result["led_blinking"] = g_blink.active;
    result["firmware"] = String(cfg::firmware_major) + "." + String(cfg::firmware_minor);
    result["uptime_s"] = millis() / 1000;
    JsonArray arr = result["pins"].to<JsonArray>();
    for (size_t i = 0; i < pins::count; ++i) {
      JsonObject p = arr.add<JsonObject>();
      p["gpio"] = pins::table[i].gpio;
      JsonArray caps = p["capabilities"].to<JsonArray>();
      const uint8_t f = pins::table[i].flags;
      if (pins::has(f, pins::Capability::input)) caps.add("input");
      if (pins::has(f, pins::Capability::output)) caps.add("output");
      if (pins::has(f, pins::Capability::pwm)) caps.add("pwm");
      if (pins::has(f, pins::Capability::strapping)) caps.add("strapping");
      if (pins::has(f, pins::Capability::led)) caps.add("onboard_led");
      p["mode"] = mode_name(g_pins[i].mode);
      p["value"] = g_pins[i].mode == proto::Mode::pwm ? g_pins[i].value : read_level(static_cast<int>(i));
    }
    JsonObject w = result["wifi"].to<JsonObject>();
    w["state"] = static_cast<int>(g_wifi.state());
    w["ssid"] = g_wifi.ssid();
    w["ip"] = g_wifi.ip().toString();
    w["hostname"] = g_wifi.hostname();
    w["rssi"] = g_wifi.rssi();
    fill_script_status(result["script"].to<JsonObject>());
    return true;
  }
  if (name == "esp32_set_led") {
    const uint8_t p[] = {static_cast<uint8_t>((args["on"] | false) ? 1 : 0)};
    if (!cloud_exec(proto::Op::led_set, p, 1, reply, error)) return false;
    result["led_on"] = reply.payload_len >= 2 && reply.payload[1] != 0;
    return true;
  }
  if (name == "esp32_blink_led") {
    const int count = args["count"] | 3, period = args["period_ms"] | 300;
    const uint8_t p[] = {static_cast<uint8_t>(count), static_cast<uint8_t>(period >> 8), static_cast<uint8_t>(period)};
    if (!cloud_exec(proto::Op::led_blink, p, 3, reply, error)) return false;
    result["ok"] = true;
    return true;
  }
  if (name == "esp32_write_pin") {
    uint8_t gpio;
    if (!gpio_arg(gpio)) return false;
    const bool high = args["high"] | false;
    const uint8_t p[] = {gpio, static_cast<uint8_t>(high ? 1 : 0)};
    if (!cloud_exec(proto::Op::pin_write, p, 2, reply, error)) return false;
    result["gpio"] = gpio; result["high"] = high;
    return true;
  }
  if (name == "esp32_read_pin") {
    uint8_t gpio;
    if (!gpio_arg(gpio)) return false;
    if (!cloud_exec(proto::Op::pin_read, &gpio, 1, reply, error)) return false;
    result["gpio"] = gpio; result["high"] = reply.payload_len >= 2 && reply.payload[1] != 0;
    return true;
  }
  if (name == "esp32_set_pin_mode") {
    uint8_t gpio;
    if (!gpio_arg(gpio)) return false;
    const String mode = args["mode"] | "";
    uint8_t m = 0;
    if (mode == "output") m = 1; else if (mode == "input") m = 2; else if (mode == "input_pullup") m = 3;
    else if (mode == "input_pulldown") m = 4; else if (mode == "pwm") m = 5;
    else { error = "unknown mode"; return false; }
    const uint8_t p[] = {gpio, m};
    if (!cloud_exec(proto::Op::pin_mode, p, 2, reply, error)) return false;
    result["gpio"] = gpio; result["mode"] = mode;
    return true;
  }
  if (name == "esp32_set_pwm") {
    uint8_t gpio;
    if (!gpio_arg(gpio)) return false;
    const int duty = args["duty"] | -1;
    if (duty < 0 || duty > 255) { error = "duty must be 0-255"; return false; }
    const uint8_t p[] = {gpio, static_cast<uint8_t>(duty)};
    if (!cloud_exec(proto::Op::pin_pwm, p, 2, reply, error)) return false;
    result["gpio"] = gpio; result["duty"] = duty;
    return true;
  }
  if (name == "esp32_pulse_pin") {
    uint8_t gpio;
    if (!gpio_arg(gpio)) return false;
    const bool high = args["high"] | true;
    const int ms = args["duration_ms"] | 200;
    const uint8_t p[] = {gpio, static_cast<uint8_t>(high ? 1 : 0), static_cast<uint8_t>(ms >> 8), static_cast<uint8_t>(ms)};
    if (!cloud_exec(proto::Op::pin_pulse, p, 4, reply, error)) return false;
    result["ok"] = true;
    return true;
  }
  if (name == "esp32_all_off") {
    if (!cloud_exec(proto::Op::all_off, nullptr, 0, reply, error)) return false;
    result["ok"] = true;
    return true;
  }
  if (name == "esp32_upload_script") {
    const char* source = args["source"] | "";
    const size_t len = strlen(source);
    if (len == 0) { error = "source is empty"; return false; }
    const String sname = args["name"] | "script";
    const bool autostart = args["autostart"] | true;
    if (!g_script.upload_begin(static_cast<uint16_t>(len), autostart, sname)) { error = "script too large (16 KB max)"; return false; }
    for (size_t off = 0; off < len; off += 200) {
      const size_t n = len - off < 200 ? len - off : 200;
      if (!g_script.upload_chunk(static_cast<uint16_t>(off), reinterpret_cast<const uint8_t*>(source) + off, n)) {
        error = "upload failed"; return false;
      }
    }
    log_push("— uploading '" + sname + "' (" + String(len) + " bytes)");
    String message;
    if (!g_script.upload_commit(proto::crc8(reinterpret_cast<const uint8_t*>(source), len), message)) {
      result["ok"] = false;
      result["compile_error"] = message;
      return true;
    }
    result["ok"] = true;
    result["state"] = script_state_name(g_script.state());
    result["name"] = sname;
    result["bytes"] = len;
    return true;
  }
  if (name == "esp32_script_status") {
    fill_script_status(result.to<JsonObject>());
    JsonArray log = result["log"].to<JsonArray>();
    portENTER_CRITICAL(&g_log_mux);
    for (size_t i = 0; i < g_log_count; ++i) {
      log.add(g_log[(g_log_head + log_lines - g_log_count + i) % log_lines]);
    }
    portEXIT_CRITICAL(&g_log_mux);
    return true;
  }
  if (name == "esp32_script_control") {
    const String action = args["action"] | "";
    String message;
    if (action == "start") { if (!g_script.start(message)) { error = message; return false; } }
    else if (action == "stop") g_script.stop();
    else if (action == "delete") g_script.remove();
    else { error = "action must be start, stop or delete"; return false; }
    result["ok"] = true;
    result["state"] = script_state_name(g_script.state());
    return true;
  }
  error = "unknown skill";
  return false;
}

// Payload: four length-prefixed strings — server url, pairing code, CF id, CF secret.
void handle_cloud_set(const proto::Request& r) {
  constexpr proto::Op op = proto::Op::cloud_set;
  String parts[4];
  size_t cur = 0;
  for (int i = 0; i < 4; ++i) {
    if (cur >= r.payload_len) { send_status(op, proto::Status::bad_arg); return; }
    const size_t n = r.payload[cur++];
    if (cur + n > r.payload_len) { send_status(op, proto::Status::bad_arg); return; }
    parts[i] = String(reinterpret_cast<const char*>(r.payload + cur), n);
    cur += n;
  }
  if (g_wifi.state() != proto::WifiState::connected) {
    send_script_error(op, "join a Wi‑Fi network first");
    return;
  }
  // Accept now, pair on a clean boot: the TLS handshake needs large contiguous
  // buffers, and a heap the Bluetooth stack has lived in is too fragmented even after
  // the stack is stopped. The app learns the outcome from CLOUD_STATUS once the
  // board is back.
  g_cloud.stage_pairing(parts[0], parts[1], parts[2], parts[3]);
  send_status(op, proto::Status::ok);
  g_cloud.request_reboot(400);
}

// On a pairing boot Bluetooth was never started; wait for Wi‑Fi, pair, restart.
void service_pairing_boot(uint32_t now) {
  if (!g_pairing_boot) return;
  constexpr uint32_t wifi_wait_ms = 45000;
  if (g_wifi.state() == proto::WifiState::connected) {
    Serial.printf("[cloud] pairing boot: Wi‑Fi up, free %u / largest block %u\n", ESP.getFreeHeap(), ESP.getMaxAllocHeap());
    String error;
    if (g_cloud.run_pending_pairing(error)) Serial.println("[cloud] pairing ok");
    else Serial.printf("[cloud] pairing failed: %s\n", error.c_str());
    g_pairing_boot = false;
    g_cloud.request_reboot(200);
  } else if (now - g_pairing_boot_started > wifi_wait_ms) {
    Serial.println("[cloud] pairing boot: Wi‑Fi never came up");
    g_cloud.clear_pending_pairing();
    g_pairing_boot = false;
    g_cloud.request_reboot(200);
  }
}

void handle_cloud_status(const proto::Request&) {
  proto::FrameBuilder fb;
  fb.begin_response(proto::Op::cloud_status, proto::Status::ok);
  fb.push(static_cast<uint8_t>(g_cloud.state()));
  fb.push(g_cloud.cloud_mode() ? 1 : 0);
  fb.push_string(g_cloud.server().c_str(), 80);
  fb.push_string(g_cloud.last_error().c_str(), 100);
  send_frame(fb);
}

// The app asked for Bluetooth while the board runs on its own link: keep the session,
// come back as a Bluetooth peripheral. The auto-switch re-arms once the phone is gone.
void handle_cloud_pause(const proto::Request&) {
  send_status(proto::Op::cloud_pause, proto::Status::ok);
  if (g_cloud_boot) {
    g_cloud.disarm();
    g_cloud.request_reboot(600);
  }
}

// A set-up board runs on its own: if it is linked to Jarvis, on Wi‑Fi, and no phone has
// been connected for a while, switch into cloud mode. After an automatic fallback the
// wait is longer so a flaky server doesn't make the board flap between modes.
void service_auto_cloud(uint32_t now) {
  if (g_cloud_boot || g_pairing_boot || !g_cloud.paired()) return;
  const bool phone = g_ble_connected || g_wifi.client_connected();
  if (phone || g_wifi.state() != proto::WifiState::connected) { g_unattended_since_ms = 0; return; }
  if (g_unattended_since_ms == 0) { g_unattended_since_ms = now; return; }
  if (now - g_unattended_since_ms < g_auto_cloud_delay_ms) return;
  Serial.println("[cloud] no phone around; switching to the direct Jarvis link");
  g_cloud.arm();
  g_cloud.request_reboot(200);
  g_unattended_since_ms = 0;
}

void handle_cloud_forget(const proto::Request&) {
  const bool was_cloud = g_cloud_boot;
  g_cloud.forget();
  send_status(proto::Op::cloud_forget, proto::Status::ok);
  if (was_cloud) g_cloud.request_reboot(600);  // come back with Bluetooth on
}

// A script's jarvis.* call while the board is on the bridge: no phone needed.
// Runs on the Lua task; the HTTPS calls block only that task.
void handle_jarvis_call_direct(const proto::Request& req) {
  if (req.payload_len < 4) return;
  const uint16_t id = static_cast<uint16_t>((req.payload[0] << 8) | req.payload[1]);
  const size_t name_len = req.payload[2];
  if (3 + name_len > req.payload_len) return;
  const String name(reinterpret_cast<const char*>(req.payload + 3), name_len);
  const String json(reinterpret_cast<const char*>(req.payload + 3 + name_len), req.payload_len - 3 - name_len);
  log_push("→ jarvis." + name + " " + json);
  bool ok = false;
  String text;
  if (name == "notify") {
    JsonDocument args;
    deserializeJson(args, json);
    ok = g_cloud.notify(args["title"] | "Jarvis ESP32", args["body"] | "");
    text = ok ? "notification sent" : "notification failed";
  } else {
    bool handled = false;
    ok = g_cloud.invoke_skill(name, json, handled, text);
    if (!handled) {
      String error;
      const String prompt = "[board event] " + String(cfg::device_name_prefix) + " · script \"" + g_script.name() +
                            "\" asks: `" + name + "` " + json + ". Do it with your tools; reply in one line.";
      ok = g_cloud.agent_turn(prompt, error);
      text = ok ? "sent to Jarvis" : error;
    }
  }
  log_push(String("← ") + (ok ? "ok: " : "failed: ") + text);
  proto::FrameBuilder fb;
  fb.begin(static_cast<uint8_t>(proto::Op::jarvis_result));
  fb.push_u16(id);
  fb.push(ok ? 1 : 0);
  fb.push_bytes(reinterpret_cast<const uint8_t*>(text.c_str()), text.length() > 200 ? 200 : text.length());
  const size_t n = fb.finish();
  if (n) g_script.deliver_event(fb.data(), n);
}

// Everything the script runtime emits: console lines are kept for the bridge, and a
// jarvis_call is answered here when the board is on the bridge, otherwise it goes to
// the phone like every other event.
void on_script_emit(const uint8_t* frame, size_t len) {
  proto::Request req{};
  if (proto::decode(frame, len, req) == proto::Status::ok) {
    if (req.op == static_cast<uint8_t>(proto::Event::script_output)) {
      log_push(String(reinterpret_cast<const char*>(req.payload), req.payload_len));
    } else if (req.op == static_cast<uint8_t>(proto::Event::jarvis_call) && g_cloud.connected()) {
      handle_jarvis_call_direct(req);
      return;
    }
  }
  broadcast_raw(frame, len);
}

bool key_matches(const uint8_t* candidate) {
  uint8_t diff = 0;
  for (size_t i = 0; i < proto::token_len; ++i) diff |= candidate[i] ^ g_owner_key[i];
  return diff == 0;
}

void save_owner_key() {
  Preferences prefs;
  if (!prefs.begin(prefs_namespace, /*readOnly=*/false)) return;
  prefs.putBytes(key_owner, g_owner_key, sizeof(g_owner_key));
  prefs.end();
}

// First contact: the phone mints the key. Only ever accepted on the bonded BLE link
// and only while the board has no owner.
void handle_claim(const proto::Request& r) {
  constexpr proto::Op op = proto::Op::claim;
  if (!require_ble(op)) return;
  if (g_claimed) { send_status(op, proto::Status::already_claimed); return; }
  if (r.payload_len != proto::token_len) { send_status(op, proto::Status::bad_arg); return; }
  memcpy(g_owner_key, r.payload, proto::token_len);
  g_claimed = true;
  g_ble_authorized = true;
  save_owner_key();
  Serial.println("[auth] board claimed by this phone");
  send_status(op, proto::Status::ok);
}

// Reset ownership without a laptop: the phone sends this while the user holds
// BOOT. Without the button it is refused (unauthorized). Clears the key, drops
// this session's authorisation and the Wi‑Fi/cloud pairing tied to the old owner.
void handle_reset_owner(const proto::Request& r) {
  constexpr proto::Op op = proto::Op::reset_owner;
  if (digitalRead(boot_button_gpio) != LOW) { send_status(op, proto::Status::unauthorized); return; }
  memset(g_owner_key, 0, sizeof(g_owner_key));
  g_claimed = false;
  g_ble_authorized = false;
  {
    Preferences prefs;
    if (prefs.begin(prefs_namespace, /*readOnly=*/false)) { prefs.remove(key_owner); prefs.end(); }
  }
  Serial.println("[auth] ownership reset (BOOT held); board is unclaimed");
  send_status(op, proto::Status::ok);
}

void handle_auth(const proto::Request& r) {
  constexpr proto::Op op = proto::Op::auth;
  if (!g_claimed || r.payload_len != proto::token_len || !key_matches(r.payload)) {
    send_status(op, proto::Status::unauthorized);
    if (g_reply_link == Link::tcp) g_wifi.drop_client();
    Serial.println("[auth] rejected");
    return;
  }
  if (g_reply_link == Link::tcp) g_wifi.mark_authenticated(); else g_ble_authorized = true;
  send_status(op, proto::Status::ok);
  Serial.printf("[auth] %s session authorised\n", g_reply_link == Link::tcp ? "tcp" : "ble");
}

void dispatch(const uint8_t* bytes, size_t len, Link link) {
  g_reply_link = link;
  proto::Request req{};
  const proto::Status st = proto::decode(bytes, len, req);
  if (st != proto::Status::ok) {
    proto::FrameBuilder fb;
    fb.begin(proto::response_bit);  // opcode 0x80: "could not even parse this"
    fb.push(static_cast<uint8_t>(st));
    send_frame(fb);
    return;
  }
  const proto::Op op = static_cast<proto::Op>(req.op);
  // Before AUTH only PING (so the app can read the claimed flag) and CLAIM/AUTH pass.
  const bool session_ok = (link == Link::script || link == Link::cloud) ? true
                        : link == Link::tcp ? g_wifi.client_authenticated() : g_ble_authorized;
  const bool open_op = op == proto::Op::ping || op == proto::Op::auth || op == proto::Op::claim;
  if (!session_ok && !open_op) {
    proto::FrameBuilder fb;
    fb.begin(req.op | proto::response_bit);
    fb.push(static_cast<uint8_t>(proto::Status::unauthorized));
    send_frame(fb);
    if (link == Link::tcp) g_wifi.drop_client();
    return;
  }
  switch (op) {
    case proto::Op::ping:        handle_ping(req); break;
    case proto::Op::get_info:    handle_get_info(req); break;
    case proto::Op::get_state:   handle_get_state(req); break;
    case proto::Op::led_set:     handle_led_set(req); break;
    case proto::Op::led_blink:   handle_led_blink(req); break;
    case proto::Op::pin_mode:    handle_pin_mode(req); break;
    case proto::Op::pin_write:   handle_pin_write(req); break;
    case proto::Op::pin_read:    handle_pin_read(req); break;
    case proto::Op::pin_pwm:     handle_pin_pwm(req); break;
    case proto::Op::pin_pulse:   handle_pin_pulse(req); break;
    case proto::Op::all_off:     handle_all_off(req); break;
    case proto::Op::wifi_set:    handle_wifi_set(req); break;
    case proto::Op::wifi_status: handle_wifi_status(req); break;
    case proto::Op::wifi_forget: handle_wifi_forget(req); break;
    case proto::Op::auth:        handle_auth(req); break;
    case proto::Op::claim:       handle_claim(req); break;
    case proto::Op::reset_owner: handle_reset_owner(req); break;
    case proto::Op::wifi_scan:   handle_wifi_scan(req); break;
    case proto::Op::script_begin:  handle_script_begin(req); break;
    case proto::Op::script_chunk:  handle_script_chunk(req); break;
    case proto::Op::script_commit: handle_script_commit(req); break;
    case proto::Op::script_stop:   g_script.stop(); send_status(op, proto::Status::ok); break;
    case proto::Op::script_start:  handle_script_start(req); break;
    case proto::Op::script_status: handle_script_status(req); break;
    case proto::Op::script_delete: g_script.remove(); send_status(op, proto::Status::ok); break;
    case proto::Op::jarvis_result: handle_jarvis_result(req); break;
    case proto::Op::cloud_set:     handle_cloud_set(req); break;
    case proto::Op::cloud_status:  handle_cloud_status(req); break;
    case proto::Op::cloud_forget:  handle_cloud_forget(req); break;
    case proto::Op::cloud_pause:   handle_cloud_pause(req); break;
    default: {
      proto::FrameBuilder fb;
      fb.begin(req.op | proto::response_bit);
      fb.push(static_cast<uint8_t>(proto::Status::unknown_op));
      send_frame(fb);
    }
  }
}

// ───────────────────────────── Periodic work ─────────────────────────────

void service_blink(uint32_t now) {
  if (!g_blink.active || static_cast<int32_t>(now - g_blink.next_toggle_ms) < 0) return;
  const int index = pins::index_of(pins::onboard_led_gpio);
  write_level(index, !g_pins[index].value);
  if (g_blink.toggles_left == 0) {
    cancel_blink();
    proto::FrameBuilder fb;
    fb.begin_event(proto::Event::blink_done);
    broadcast_event(fb);
    return;
  }
  --g_blink.toggles_left;
  g_blink.next_toggle_ms = now + g_blink.period_ms / 2;
}

void service_pulses(uint32_t now) {
  for (size_t i = 0; i < pins::count; ++i) {
    PinState& s = g_pins[i];
    if (!s.pulse_active || static_cast<int32_t>(now - s.pulse_deadline_ms) < 0) continue;
    s.pulse_active = false;
    write_level(static_cast<int>(i), s.pulse_return_level);
    proto::FrameBuilder fb;
    fb.begin_event(proto::Event::pulse_done);
    fb.push(pins::table[i].gpio);
    fb.push(s.value);
    broadcast_event(fb);
  }
}

void service_inputs(uint32_t now) {
  if (now - g_last_input_poll_ms < cfg::input_poll_ms) return;
  g_last_input_poll_ms = now;
  for (size_t i = 0; i < pins::count; ++i) {
    PinState& s = g_pins[i];
    if (!is_input_mode(s.mode)) continue;
    const uint8_t raw = digitalRead(pins::table[i].gpio) ? 1 : 0;
    if (raw != s.candidate_level) {
      s.candidate_level = raw;
      s.candidate_since_ms = now;
      continue;
    }
    if (raw != s.stable_level && now - s.candidate_since_ms >= cfg::input_debounce_ms) {
      s.stable_level = raw;
      s.value = raw;
      proto::FrameBuilder fb;
      fb.begin_event(proto::Event::input_changed);
      fb.push(pins::table[i].gpio);
      fb.push(raw);
      broadcast_event(fb);
    }
  }
}

// Slow heartbeat on the LED while nobody is connected on either link. Stops the
// moment a phone connects so it never fights the app; the app then owns the LED.
void service_link_led(uint32_t now) {
  // The blink means "needs setup": only an unclaimed board shows it. A set-up board's
  // LED belongs to scripts and the app, whether or not a phone is around.
  if (!cfg::led_shows_link_state || g_blink.active || g_script.running()) return;
  if (g_claimed || g_ble_connected || g_wifi.client_authenticated()) {
    if (g_link_led_level) { g_link_led_level = false; write_level(pins::index_of(pins::onboard_led_gpio), 0); }
    return;
  }
  const uint32_t period = link_blink_period_ms;
  if (now - g_last_link_blink_ms < period / 2) return;
  g_last_link_blink_ms = now;
  g_link_led_level = !g_link_led_level;
  write_level(pins::index_of(pins::onboard_led_gpio), g_link_led_level);
}

// ───────────────────────────── BLE callbacks (BT task) ─────────────────────────────

class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer* server, esp_ble_gatts_cb_param_t* param) override {
    g_conn_id = param->connect.conn_id;
    g_ble_connected = true;
    g_ble_authenticated = false;
    g_ble_authorized = false;
    // iOS starts at a 30 ms+ connection interval; ask for 15–30 ms (units of
    // 1.25 ms) so every command round-trip is a fraction of what it was.
    server->updateConnParams(param->connect.remote_bda, 12, 24, 0, 400);
    Serial.println("[ble] connected");
  }
  void onDisconnect(BLEServer*) override {
    g_ble_connected = false;
    g_ble_authenticated = false;
    g_ble_authorized = false;
    Serial.println("[ble] disconnected, advertising again");
  }
  void onMtuChanged(BLEServer*, esp_ble_gatts_cb_param_t* param) override {
    Serial.printf("[ble] mtu %u\n", param->mtu.mtu);
  }
};

class CommandCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* c) override {
    const size_t len = c->getLength();
    if (len == 0 || len > proto::max_frame) {
      g_dropped_frames = g_dropped_frames + 1;
      return;
    }
    IncomingFrame f;
    f.len = static_cast<uint8_t>(len);
    memcpy(f.bytes, c->getData(), len);
    if (xQueueSend(g_rx_queue, &f, 0) != pdTRUE) g_dropped_frames = g_dropped_frames + 1;
  }
};

class SecurityCallbacks : public BLESecurityCallbacks {
  uint32_t onPassKeyRequest() override { return 0; }
  void onPassKeyNotify(uint32_t) override {}
  bool onSecurityRequest() override { return true; }
  bool onConfirmPIN(uint32_t) override { return true; }
  void onAuthenticationComplete(esp_ble_auth_cmpl_t desc) override {
    if (desc.success) {
      g_ble_authenticated = true;
      Serial.println("[ble] paired and encrypted");
    } else {
      Serial.printf("[ble] pairing failed (0x%02x), dropping link\n", desc.fail_reason);
      if (g_server) g_server->disconnect(g_conn_id);
    }
  }
};

String device_name() {
  char buf[32];
  snprintf(buf, sizeof(buf), "%s-%02X%02X", cfg::device_name_prefix, g_mac[4], g_mac[5]);
  return String(buf);
}

// A different build stamp means the board was reflashed: forget the owner so the
// next phone to connect starts from a clean board. The Wi‑Fi network is kept — it is
// configuration, not a credential for the board itself.
void reset_if_reflashed() {
  Preferences prefs;
  if (!prefs.begin(prefs_namespace, /*readOnly=*/false)) return;
  const String stored = prefs.getString(key_build, "");
  if (stored != build_stamp) {
    prefs.remove(key_owner);
    prefs.putString(key_build, build_stamp);
    Serial.println("[auth] new firmware build, ownership reset");
  }
  prefs.end();
}

void load_owner_key() {
  Preferences prefs;
  if (!prefs.begin(prefs_namespace, /*readOnly=*/true)) return;
  if (prefs.getBytesLength(key_owner) == sizeof(g_owner_key)) {
    prefs.getBytes(key_owner, g_owner_key, sizeof(g_owner_key));
    g_claimed = true;
  }
  prefs.end();
  Serial.println(g_claimed ? "[auth] board is claimed" : "[auth] board is unclaimed, first phone to connect owns it");
}

void setup_ble(const String& name) {
  // Classic Bluetooth is never used; releasing its controller memory before init
  // hands ~30 KB back to the heap and the core starts the controller BLE-only.
  btMemRelease(BT_MODE_CLASSIC_BT);
  BLEDevice::init(name.c_str());
  BLEDevice::setMTU(247);

  // "Just Works" LE Secure Connections with NO bonding: the link is encrypted on every
  // connection, but neither side stores long-term keys. A stored bond on the phone with
  // none on the board (after a reflash or NVS loss) makes iOS refuse to reconnect with
  // "peer removed pairing information"; without bonds that mismatch cannot happen. The
  // board's real access control is the owner key, not the bond.
  BLESecurity* security = new BLESecurity();
  security->setCapability(ESP_IO_CAP_NONE);
  security->setAuthenticationMode(/*bonding=*/false, /*mitm=*/false, /*sc=*/true);
  BLEDevice::setSecurityCallbacks(new SecurityCallbacks());

  g_server = BLEDevice::createServer();
  g_server->setCallbacks(new ServerCallbacks());
  g_server->advertiseOnDisconnect(true);

  BLEService* service = g_server->createService(proto::service_uuid);

  BLECharacteristic* command = service->createCharacteristic(
      proto::command_uuid,
      BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR);
  command->setAccessPermissions(ESP_GATT_PERM_WRITE_ENCRYPTED);  // encrypted, unbonded is fine
  command->setCallbacks(new CommandCallbacks());

  g_event_char = service->createCharacteristic(
      proto::event_uuid,
      BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY);
  g_event_char->setAccessPermissions(ESP_GATT_PERM_READ_ENCRYPTED);
  // Bluedroid needs the CCCD added by hand. Encrypting it means subscribing is what
  // triggers the (code-less) pairing prompt if the phone hasn't bonded yet.
  BLE2902* cccd = new BLE2902();
  cccd->setAccessPermissions(ESP_GATT_PERM_READ_ENCRYPTED | ESP_GATT_PERM_WRITE_ENCRYPTED);
  g_event_char->addDescriptor(cccd);

  service->start();

  BLEAdvertising* adv = BLEDevice::getAdvertising();
  adv->addServiceUUID(proto::service_uuid);
  adv->setScanResponse(true);
  adv->setMinPreferred(0x06);  // recommended connection-interval hints for iOS
  adv->setMaxPreferred(0x12);
  BLEDevice::startAdvertising();

  Serial.printf("[ble] advertising as %s\n", name.c_str());
}

}  // namespace

// ───────────────────────────── Arduino entry points ─────────────────────────────

void setup() {
  Serial.begin(cfg::serial_baud);
  delay(100);
  Serial.printf("\nJarvis ESP32 firmware %u.%u, protocol %u\n",
                cfg::firmware_major, cfg::firmware_minor, proto::version);

  g_rx_queue = xQueueCreate(rx_queue_depth, sizeof(IncomingFrame));
  configASSERT(g_rx_queue != nullptr);

  // Only the LED gets a defined state at boot. Every other pin stays as the chip left
  // it (high-impedance input) until the app asks for something.
  apply_mode(pins::index_of(pins::onboard_led_gpio), proto::Mode::output);

  esp_read_mac(g_mac, ESP_MAC_BT);
  reset_if_reflashed();
  load_owner_key();
  Serial.printf("[mem] free heap before radios: %u bytes\n", ESP.getFreeHeap());

  const String name = device_name();
  g_cloud.begin(skills_json, run_skill);
  g_cloud_boot = g_cloud.cloud_mode();
  g_pairing_boot = g_cloud.has_pending_pairing();
  g_pairing_boot_started = millis();
  if (g_cloud.came_from_fallback()) g_auto_cloud_delay_ms = 10 * 60 * 1000;
  pinMode(boot_button_gpio, INPUT_PULLUP);  // hold BOOT 3 s at runtime → back to Bluetooth mode
  if (g_pairing_boot) {
    Serial.println("[boot] pairing boot: Bluetooth off, pairing with Jarvis once Wi‑Fi is up");
  } else if (g_cloud_boot) {
    Serial.println("[boot] cloud mode: Bluetooth off, holding the Jarvis bridge over Wi‑Fi");
  } else {
    setup_ble(name);
    Serial.printf("[mem] free heap after BLE: %u bytes\n", ESP.getFreeHeap());
  }
  // Same name as the BLE advertisement, lower-cased, becomes `<name>.local` on the LAN.
  String host = name;
  host.toLowerCase();
  g_wifi.begin(host, [](const uint8_t* frame, size_t len) { dispatch(frame, len, Link::tcp); });
  Serial.printf("[mem] free heap after Wi‑Fi: %u bytes\n", ESP.getFreeHeap());
  // A pairing boot is short-lived; leave the script and its heap out of it.
  if (!g_pairing_boot) {
    g_script.begin([](const uint8_t* frame, size_t len) { dispatch(frame, len, Link::script); },
                   [](const uint8_t* frame, size_t len) { on_script_emit(frame, len); },
                   []() { return g_ble_connected || g_wifi.client_authenticated() || g_cloud.connected(); });
  }
  Serial.printf("[mem] free heap after setup: %u bytes\n", ESP.getFreeHeap());
}

void loop() {
  IncomingFrame in;
  while (xQueueReceive(g_rx_queue, &in, 0) == pdTRUE) {
    dispatch(in.bytes, in.len, Link::ble);
  }

  const uint32_t now = millis();
  g_wifi.service(now);
  if (g_wifi.take_state_changed()) send_wifi_changed();
  service_pairing_boot(now);
  if (!g_pairing_boot) g_cloud.service(now, g_wifi.state() == proto::WifiState::connected);
  service_auto_cloud(now);
  if (g_cloud.take_state_changed()) send_cloud_changed();
  if (!g_pairing_boot) g_script.service(now);

  // BOOT button held: leave cloud mode so a phone can reach the board over Bluetooth.
  if (g_cloud_boot) {
    if (digitalRead(boot_button_gpio) == LOW) {
      if (g_boot_pressed_ms == 0) g_boot_pressed_ms = now;
      else if (now - g_boot_pressed_ms > boot_button_hold_ms) {
        Serial.println("[boot] BOOT held, rebooting into Bluetooth mode");
        g_cloud.disarm();
        g_cloud.request_reboot(100);
        g_boot_pressed_ms = 0;
      }
    } else {
      g_boot_pressed_ms = 0;
    }
  }
  if (g_cloud.wants_reboot()) {
    Serial.println("[boot] restarting");
    Serial.flush();
    delay(50);
    ESP.restart();
  }

  service_blink(now);
  service_pulses(now);
  service_inputs(now);
  service_link_led(now);

  static uint32_t reported_drops = 0;
  if (g_dropped_frames != reported_drops) {
    reported_drops = g_dropped_frames;
    Serial.printf("[rx] dropped frames so far: %lu\n", static_cast<unsigned long>(reported_drops));
  }

  delay(2);
}
