// Sandboxed Lua 5.4 runtime that lets the app (and Jarvis, through the app) program
// the board without reflashing. The base firmware stays in charge of BLE, Wi‑Fi,
// ownership and the GPIO state machine; a script is just another client of the same
// command protocol, running in its own FreeRTOS task.
//
// Threading model
//   Lua task  ── request frame ──▶ cmd queue ──▶ loop(): dispatch(Link::script)
//   Lua task  ◀── reply frame ─── reply queue ◀── send_frame()
//   loop()    ── event frame ───▶ event queue ──▶ Lua task's event loop
// The Lua task never touches pin state directly, so the GPIO code stays single-threaded.
//
// Script programming model (documented for the AI in firmware/README.md):
//   gpio.mode(pin, "input_pullup")   gpio.write(pin, 1)   gpio.read(pin)
//   gpio.pwm(pin, duty)              gpio.pulse(pin, level, ms)
//   led.set(true)                    led.blink(n, period_ms)
//   on_input(pin, function(level) … end)     -- debounced edges, needs an input mode
//   every(ms, fn)   after(ms, fn)   sleep_ms(ms)   millis()   print(…)
//   jarvis.notify(title, body)       jarvis.invoke(name, args_table [, function(ok, text) … end])
//   wifi.status()  → { state=…, ip=…, ssid=… }
// After the chunk runs, the runtime keeps the script alive while it has callbacks or
// timers registered; with none it reports `finished`.
#ifndef JARVIS_ESP32_SCRIPT_RUNTIME_H
#define JARVIS_ESP32_SCRIPT_RUNTIME_H

#include <Arduino.h>
#include <freertos/FreeRTOS.h>
#include <freertos/queue.h>
#include <freertos/task.h>
#include <functional>

#include "Protocol.h"

struct lua_State;
struct lua_Debug;

namespace jarvis {

class ScriptRuntime {
 public:
  /// Called from loop() with a request frame the script sent; the sketch dispatches it
  /// and answers through `deliver_reply`.
  using Dispatcher = std::function<void(const uint8_t* frame, size_t len)>;
  /// Broadcast an event frame to the phone(s).
  using Emitter = std::function<void(const uint8_t* frame, size_t len)>;
  /// True when something can actually answer a jarvis.* call right now (a phone on
  /// BLE/TCP, or the board's own bridge). Without it a call is failed immediately
  /// instead of waiting on an answer that can never come.
  using LinkProbe = std::function<bool()>;

  struct Frame {
    uint8_t len;
    uint8_t bytes[proto::max_frame];
  };

  ScriptRuntime() = default;
  ScriptRuntime(const ScriptRuntime&) = delete;
  ScriptRuntime& operator=(const ScriptRuntime&) = delete;

  /// Mounts storage, loads the stored script and autostarts it if flagged.
  void begin(Dispatcher dispatch, Emitter emit, LinkProbe has_link);

  // ── Upload (from the phone) ──
  bool upload_begin(uint16_t total, bool autostart, const String& name);
  bool upload_chunk(uint16_t offset, const uint8_t* data, size_t len);
  /// Verifies the CRC, stores the script, and starts it. Returns false with `message`
  /// set on CRC mismatch or compile error.
  bool upload_commit(uint8_t crc, String& message);

  bool start(String& message);
  void stop();
  void remove();

  proto::ScriptState state() const { return state_; }
  bool autostart() const { return autostart_; }
  uint16_t size() const { return static_cast<uint16_t>(source_.length()); }
  const String& name() const { return name_; }
  const String& last_error() const { return last_error_; }

  // ── Called from loop() ──
  /// Pumps script requests through the dispatcher and reaps a finished task.
  void service(uint32_t now);
  /// The reply to the request currently being dispatched (routed from send_frame).
  void deliver_reply(const uint8_t* frame, size_t len);
  /// Copies an event (or a jarvis_result frame) to the script's queue if one is running.
  void deliver_event(const uint8_t* frame, size_t len);
  bool running() const { return task_ != nullptr; }

  // Called from the Lua task through the C API functions.
  bool call(proto::Op op, const uint8_t* payload, size_t len, Frame& reply, uint32_t timeout_ms);
  void emit_output(const char* text);

 private:
  static void task_entry(void* arg);
  void task_main();
  static void* lua_alloc(void* ud, void* ptr, size_t osize, size_t nsize);
  static void hook(lua_State* L, lua_Debug* ar);
  void open_api(lua_State* L);
  void event_loop(lua_State* L);
  bool has_pending_work() const;
  void handle_event(lua_State* L, const Frame& f);
  void run_timers(lua_State* L, uint32_t now);
  void report_error(lua_State* L, const char* where);
  void emit_state();
  void set_state(proto::ScriptState s);
  void load_stored();
  void save_stored();

  // Lua C functions.
  static int l_gpio_mode(lua_State* L);
  static int l_gpio_write(lua_State* L);
  static int l_gpio_read(lua_State* L);
  static int l_gpio_pwm(lua_State* L);
  static int l_gpio_pulse(lua_State* L);
  static int l_led_set(lua_State* L);
  static int l_led_blink(lua_State* L);
  static int l_on_input(lua_State* L);
  static int l_every(lua_State* L);
  static int l_after(lua_State* L);
  static int l_sleep_ms(lua_State* L);
  static int l_millis(lua_State* L);
  static int l_print(lua_State* L);
  static int l_jarvis_invoke(lua_State* L);
  static int l_jarvis_notify(lua_State* L);
  static int l_wifi_status(lua_State* L);
  static ScriptRuntime* self(lua_State* L);

  Dispatcher dispatch_;
  Emitter emit_;
  LinkProbe has_link_;

  String source_;
  String name_;
  bool autostart_ = false;
  String last_error_;
  proto::ScriptState state_ = proto::ScriptState::none;

  // Upload staging.
  String staging_;
  uint16_t staging_total_ = 0;
  bool staging_autostart_ = false;
  String staging_name_;

  // Task plumbing.
  TaskHandle_t task_ = nullptr;
  volatile bool stop_requested_ = false;
  volatile bool task_done_ = false;
  QueueHandle_t cmd_queue_ = nullptr;
  QueueHandle_t reply_queue_ = nullptr;
  QueueHandle_t event_queue_ = nullptr;
  size_t lua_bytes_used_ = 0;
  size_t lua_heap_cap_ = 0;

  // Registered callbacks live in the Lua registry; these hold the refs.
  struct Timer {
    uint32_t due_ms;
    uint32_t period_ms;  // 0 = one-shot
    int ref;
  };
  static constexpr size_t max_timers = 16;
  Timer timers_[max_timers];
  size_t timer_count_ = 0;
  static constexpr size_t max_gpio = 40;
  int input_refs_[max_gpio];   // indexed by GPIO number; LUA_NOREF when unset
  static constexpr size_t max_calls = 16;
  struct PendingCall { uint16_t id; int ref; uint32_t created_ms; };
  void expire_calls(lua_State* L, uint32_t now);
  void fail_call_locally(uint16_t id, const char* reason);
  PendingCall calls_[max_calls];
  size_t call_count_ = 0;
  uint16_t next_call_id_ = 1;
};

}  // namespace jarvis

#endif  // JARVIS_ESP32_SCRIPT_RUNTIME_H
