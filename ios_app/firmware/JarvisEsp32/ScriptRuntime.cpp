#include "ScriptRuntime.h"

#include <LittleFS.h>
#include <string.h>

extern "C" {
#include "src/lua/lua.h"
#include "src/lua/lauxlib.h"
#include "src/lua/lualib.h"
}

#include "Config.h"

namespace cfg = jarvis::config;

namespace jarvis {

namespace {
constexpr const char* script_path = "/script.lua";
constexpr const char* meta_path = "/script.meta";
constexpr size_t max_script_bytes = 16 * 1024;
// The Lua heap budget is decided at start() from what is actually free: BLE and
// Wi‑Fi take most of the ESP32's RAM, so the cap is whatever remains after the task
// stack and a reserve for the radios, up to this ceiling.
constexpr size_t lua_heap_ceiling = 48 * 1024;
constexpr size_t lua_heap_floor = 10 * 1024;     // below this a script can't even load libs
constexpr size_t radio_reserve = 12 * 1024;      // left free for Wi‑Fi and BLE traffic
constexpr uint32_t hook_interval = 2000;         // VM instructions between stop checks
constexpr uint32_t reply_timeout_ms = 1000;
constexpr uint32_t task_stack_bytes = 10 * 1024;
constexpr uint8_t queue_depth = 2;               // one request in flight at a time
constexpr uint8_t event_queue_depth = 8;
constexpr const char* registry_self = "jarvis.runtime";
// A jarvis.* call nobody answered in this long gets its callback failed, freeing the
// slot — the script must keep running with the phone gone.
constexpr uint32_t call_expiry_ms = 60000;

// Minimal JSON writer for the tables scripts pass to jarvis.invoke.
void json_escape(String& out, const char* s) {
  out += '"';
  for (; *s; ++s) {
    switch (*s) {
      case '"': out += "\\\""; break;
      case '\\': out += "\\\\"; break;
      case '\n': out += "\\n"; break;
      case '\r': out += "\\r"; break;
      case '\t': out += "\\t"; break;
      default: out += *s;
    }
  }
  out += '"';
}

void json_value(lua_State* L, int idx, String& out, int depth);

void json_table(lua_State* L, int idx, String& out, int depth) {
  idx = lua_absindex(L, idx);
  const lua_Integer n = luaL_len(L, idx);
  if (n > 0) {
    out += '[';
    for (lua_Integer i = 1; i <= n; ++i) {
      if (i > 1) out += ',';
      lua_geti(L, idx, i);
      json_value(L, -1, out, depth + 1);
      lua_pop(L, 1);
    }
    out += ']';
    return;
  }
  out += '{';
  bool first = true;
  lua_pushnil(L);
  while (lua_next(L, idx) != 0) {
    if (lua_type(L, -2) == LUA_TSTRING) {
      if (!first) out += ',';
      first = false;
      json_escape(out, lua_tostring(L, -2));
      out += ':';
      json_value(L, -1, out, depth + 1);
    }
    lua_pop(L, 1);
  }
  out += '}';
}

void json_value(lua_State* L, int idx, String& out, int depth) {
  switch (lua_type(L, idx)) {
    case LUA_TNIL: out += "null"; break;
    case LUA_TBOOLEAN: out += lua_toboolean(L, idx) ? "true" : "false"; break;
    case LUA_TNUMBER:
      if (lua_isinteger(L, idx)) out += String(static_cast<long>(lua_tointeger(L, idx)));
      else out += String(static_cast<double>(lua_tonumber(L, idx)), 3);
      break;
    case LUA_TSTRING: json_escape(out, lua_tostring(L, idx)); break;
    case LUA_TTABLE:
      if (depth > 3) out += "null"; else json_table(L, idx, out, depth);
      break;
    default: out += "null";
  }
}

int check_pin(lua_State* L, int idx) {
  const lua_Integer pin = luaL_checkinteger(L, idx);
  if (pin < 0 || pin > 39) return luaL_error(L, "gpio %d out of range", static_cast<int>(pin));
  return static_cast<int>(pin);
}

int check_level(lua_State* L, int idx) {
  if (lua_isboolean(L, idx)) return lua_toboolean(L, idx) ? 1 : 0;
  return luaL_checkinteger(L, idx) != 0 ? 1 : 0;
}

const char* status_text(uint8_t st) {
  switch (static_cast<proto::Status>(st)) {
    case proto::Status::bad_pin: return "gpio not exposed";
    case proto::Status::bad_arg: return "bad argument";
    case proto::Status::not_capable: return "pin cannot do that";
    case proto::Status::busy: return "pin busy";
    case proto::Status::unauthorized: return "not authorised";
    default: return "command failed";
  }
}
}  // namespace

// Sends a command through loop() and raises a Lua error on failure. Leaves the decoded
// reply in `r_` for the caller.
#define RUN_COMMAND(L, op, ...)                                                             \
  ScriptRuntime::Frame reply;                                                               \
  {                                                                                         \
    const uint8_t payload_[] = {__VA_ARGS__};                                               \
    if (!self(L)->call(op, payload_, sizeof(payload_), reply, reply_timeout_ms))           \
      return luaL_error(L, "board did not answer");                                         \
  }                                                                                         \
  proto::Request r_{};                                                                      \
  if (proto::decode(reply.bytes, reply.len, r_) != proto::Status::ok || r_.payload_len < 1) \
    return luaL_error(L, "bad reply");                                                      \
  if (r_.payload[0] != static_cast<uint8_t>(proto::Status::ok))                             \
    return luaL_error(L, "%s", status_text(r_.payload[0]));

// ───────────────────────────── Lifecycle ─────────────────────────────

void ScriptRuntime::begin(Dispatcher dispatch, Emitter emit, LinkProbe has_link) {
  dispatch_ = std::move(dispatch);
  emit_ = std::move(emit);
  has_link_ = std::move(has_link);
  for (int& r : input_refs_) r = LUA_NOREF;
  cmd_queue_ = xQueueCreate(queue_depth, sizeof(Frame));
  reply_queue_ = xQueueCreate(queue_depth, sizeof(Frame));
  event_queue_ = xQueueCreate(event_queue_depth, sizeof(Frame));
  if (!LittleFS.begin(/*formatOnFail=*/true)) {
    Serial.println("[script] LittleFS unavailable; scripts will not persist");
    return;
  }
  load_stored();
  if (source_.length() > 0) {
    state_ = proto::ScriptState::stopped;
    if (autostart_) {
      String msg;
      if (!start(msg)) Serial.printf("[script] autostart failed: %s\n", msg.c_str());
    }
  }
}

void ScriptRuntime::load_stored() {
  File f = LittleFS.open(script_path, "r");
  if (f) { source_ = f.readString(); f.close(); }
  File m = LittleFS.open(meta_path, "r");
  if (m) {
    autostart_ = m.read() == '1';
    name_ = m.readString();
    m.close();
  }
}

void ScriptRuntime::save_stored() {
  File f = LittleFS.open(script_path, "w");
  if (f) { f.print(source_); f.close(); }
  File m = LittleFS.open(meta_path, "w");
  if (m) { m.write(autostart_ ? '1' : '0'); m.print(name_); m.close(); }
}

// ───────────────────────────── Upload ─────────────────────────────

bool ScriptRuntime::upload_begin(uint16_t total, bool autostart, const String& name) {
  if (total == 0 || total > max_script_bytes) return false;
  staging_ = "";
  staging_.reserve(total);
  staging_total_ = total;
  staging_autostart_ = autostart;
  staging_name_ = name;
  return true;
}

bool ScriptRuntime::upload_chunk(uint16_t offset, const uint8_t* data, size_t len) {
  if (staging_total_ == 0 || offset != staging_.length() || offset + len > staging_total_) return false;
  for (size_t i = 0; i < len; ++i) staging_ += static_cast<char>(data[i]);
  return true;
}

bool ScriptRuntime::upload_commit(uint8_t crc, String& message) {
  if (staging_total_ == 0 || staging_.length() != staging_total_) {
    message = "upload incomplete";
    return false;
  }
  if (proto::crc8(reinterpret_cast<const uint8_t*>(staging_.c_str()), staging_.length()) != crc) {
    message = "upload corrupted (crc)";
    staging_ = ""; staging_total_ = 0;
    return false;
  }
  stop();
  source_ = staging_;
  name_ = staging_name_;
  autostart_ = staging_autostart_;
  staging_ = ""; staging_total_ = 0;
  save_stored();
  Serial.printf("[script] stored '%s' (%u bytes)\n", name_.c_str(), source_.length());
  return start(message);
}

// ───────────────────────────── Start / stop ─────────────────────────────

bool ScriptRuntime::start(String& message) {
  stop();
  if (source_.isEmpty()) { message = "no script stored"; return false; }
  // Compile once on this task so a syntax error comes back in the response instead
  // of only as an event.
  lua_State* probe = luaL_newstate();
  if (probe == nullptr) { message = "out of memory"; return false; }
  const int rc = luaL_loadbuffer(probe, source_.c_str(), source_.length(), name_.c_str());
  if (rc != LUA_OK) {
    message = lua_tostring(probe, -1);
    lua_close(probe);
    last_error_ = message;
    set_state(proto::ScriptState::error);
    return false;
  }
  lua_close(probe);

  const size_t free_now = ESP.getFreeHeap();
  if (free_now < task_stack_bytes + radio_reserve + lua_heap_floor) {
    message = String("not enough free memory for a script (") + free_now + " bytes free)";
    last_error_ = message;
    set_state(proto::ScriptState::error);
    return false;
  }
  lua_heap_cap_ = free_now - task_stack_bytes - radio_reserve;
  if (lua_heap_cap_ > lua_heap_ceiling) lua_heap_cap_ = lua_heap_ceiling;
  Serial.printf("[script] heap budget %u bytes (free %u)\n", lua_heap_cap_, free_now);

  last_error_ = "";
  stop_requested_ = false;
  task_done_ = false;
  xQueueReset(cmd_queue_); xQueueReset(reply_queue_); xQueueReset(event_queue_);
  if (xTaskCreatePinnedToCore(task_entry, "lua", task_stack_bytes, this, 1, &task_, 1) != pdPASS) {
    task_ = nullptr;
    message = "could not start script task";
    return false;
  }
  set_state(proto::ScriptState::running);
  return true;
}

void ScriptRuntime::stop() {
  if (task_ == nullptr) return;
  stop_requested_ = true;
  // The hook raises an error at the next check; sleep_ms and the event loop also
  // watch the flag. Meanwhile keep dispatching so a blocked call() can return.
  const uint32_t deadline = millis() + 2000;
  while (!task_done_ && millis() < deadline) {
    service(millis());
    delay(5);
  }
  if (!task_done_) {
    Serial.println("[script] task did not stop, deleting it");
    vTaskDelete(task_);
  }
  task_ = nullptr;
  if (state_ == proto::ScriptState::running) set_state(proto::ScriptState::stopped);
}

void ScriptRuntime::remove() {
  stop();
  source_ = ""; name_ = ""; autostart_ = false; last_error_ = "";
  LittleFS.remove(script_path);
  LittleFS.remove(meta_path);
  set_state(proto::ScriptState::none);
}

void ScriptRuntime::set_state(proto::ScriptState s) {
  state_ = s;
  emit_state();
}

void ScriptRuntime::emit_state() {
  proto::FrameBuilder fb;
  fb.begin_event(proto::Event::script_state);
  fb.push(static_cast<uint8_t>(state_));
  const size_t n = fb.finish();
  if (n && emit_) emit_(fb.data(), n);
}

void ScriptRuntime::emit_output(const char* text) {
  Serial.printf("[script] %s\n", text);
  proto::FrameBuilder fb;
  fb.begin_event(proto::Event::script_output);
  size_t n = strlen(text);
  if (n > proto::max_body - 1) n = proto::max_body - 1;
  fb.push_bytes(reinterpret_cast<const uint8_t*>(text), n);
  const size_t len = fb.finish();
  if (len && emit_) emit_(fb.data(), len);
}

// ───────────────────────────── loop() side ─────────────────────────────

void ScriptRuntime::service(uint32_t) {
  Frame f;
  while (xQueueReceive(cmd_queue_, &f, 0) == pdTRUE) {
    if (dispatch_) dispatch_(f.bytes, f.len);
  }
  if (task_ != nullptr && task_done_) {
    task_ = nullptr;
    if (state_ == proto::ScriptState::running) set_state(proto::ScriptState::finished);
    else emit_state();  // error state was set from the task; announce it now
  }
}

void ScriptRuntime::deliver_reply(const uint8_t* frame, size_t len) {
  if (len == 0 || len > proto::max_frame) return;
  Frame f;
  f.len = static_cast<uint8_t>(len);
  memcpy(f.bytes, frame, len);
  xQueueSend(reply_queue_, &f, 0);
}

void ScriptRuntime::deliver_event(const uint8_t* frame, size_t len) {
  if (task_ == nullptr || len == 0 || len > proto::max_frame) return;
  Frame f;
  f.len = static_cast<uint8_t>(len);
  memcpy(f.bytes, frame, len);
  xQueueSend(event_queue_, &f, 0);  // drop when the script can't keep up
}

// ───────────────────────────── Lua task ─────────────────────────────

void ScriptRuntime::task_entry(void* arg) {
  static_cast<ScriptRuntime*>(arg)->task_main();
  vTaskDelete(nullptr);
}

void* ScriptRuntime::lua_alloc(void* ud, void* ptr, size_t osize, size_t nsize) {
  auto* rt = static_cast<ScriptRuntime*>(ud);
  const size_t old = ptr ? osize : 0;
  if (nsize == 0) {
    free(ptr);
    rt->lua_bytes_used_ -= old;
    return nullptr;
  }
  if (rt->lua_bytes_used_ - old + nsize > rt->lua_heap_cap_) return nullptr;
  void* p = realloc(ptr, nsize);
  if (p) rt->lua_bytes_used_ = rt->lua_bytes_used_ - old + nsize;
  return p;
}

void ScriptRuntime::hook(lua_State* L, lua_Debug*) {
  if (self(L)->stop_requested_) luaL_error(L, "stopped");
}

ScriptRuntime* ScriptRuntime::self(lua_State* L) {
  lua_getfield(L, LUA_REGISTRYINDEX, registry_self);
  auto* rt = static_cast<ScriptRuntime*>(lua_touserdata(L, -1));
  lua_pop(L, 1);
  return rt;
}

void ScriptRuntime::task_main() {
  lua_bytes_used_ = 0;
  timer_count_ = 0;
  call_count_ = 0;
  for (int& r : input_refs_) r = LUA_NOREF;

  lua_State* L = lua_newstate(lua_alloc, this);
  if (L == nullptr) {
    last_error_ = "out of memory";
    emit_output("error: out of memory");
    state_ = proto::ScriptState::error;
    task_done_ = true;
    return;
  }
  lua_pushlightuserdata(L, this);
  lua_setfield(L, LUA_REGISTRYINDEX, registry_self);

  // Safe subset of the standard library: no io, os, debug, package.
  luaL_requiref(L, LUA_GNAME, luaopen_base, 1); lua_pop(L, 1);
  luaL_requiref(L, LUA_STRLIBNAME, luaopen_string, 1); lua_pop(L, 1);
  luaL_requiref(L, LUA_TABLIBNAME, luaopen_table, 1); lua_pop(L, 1);
  luaL_requiref(L, LUA_MATHLIBNAME, luaopen_math, 1); lua_pop(L, 1);
  luaL_requiref(L, LUA_UTF8LIBNAME, luaopen_utf8, 1); lua_pop(L, 1);
  for (const char* banned : {"dofile", "loadfile", "require"}) {
    lua_pushnil(L);
    lua_setglobal(L, banned);
  }
  open_api(L);
  lua_sethook(L, hook, LUA_MASKCOUNT, hook_interval);

  if (luaL_loadbuffer(L, source_.c_str(), source_.length(), name_.c_str()) != LUA_OK ||
      lua_pcall(L, 0, 0, 0) != LUA_OK) {
    report_error(L, "script");
  } else {
    event_loop(L);
  }

  lua_close(L);
  task_done_ = true;
}

void ScriptRuntime::report_error(lua_State* L, const char* where) {
  const char* msg = lua_tostring(L, -1);
  last_error_ = msg ? msg : "unknown error";
  lua_pop(L, 1);
  if (last_error_ == "stopped" || last_error_.endsWith(": stopped")) return;
  String line = String("error in ") + where + ": " + last_error_;
  emit_output(line.c_str());
  state_ = proto::ScriptState::error;  // announced by service() when the task is reaped
}

bool ScriptRuntime::has_pending_work() const {
  if (timer_count_ > 0 || call_count_ > 0) return true;
  for (int r : input_refs_) if (r != LUA_NOREF) return true;
  return false;
}

void ScriptRuntime::event_loop(lua_State* L) {
  while (!stop_requested_ && has_pending_work()) {
    const uint32_t now = millis();
    uint32_t wait = 50;
    for (size_t i = 0; i < timer_count_; ++i) {
      const int32_t delta = static_cast<int32_t>(timers_[i].due_ms - now);
      if (delta <= 0) { wait = 0; break; }
      if (static_cast<uint32_t>(delta) < wait) wait = static_cast<uint32_t>(delta);
    }
    Frame f;
    if (xQueueReceive(event_queue_, &f, pdMS_TO_TICKS(wait)) == pdTRUE) handle_event(L, f);
    if (state_ == proto::ScriptState::error) return;
    run_timers(L, millis());
    if (state_ == proto::ScriptState::error) return;
    expire_calls(L, millis());
    if (state_ == proto::ScriptState::error) return;
  }
}

void ScriptRuntime::expire_calls(lua_State* L, uint32_t now) {
  for (size_t i = 0; i < call_count_;) {
    if (now - calls_[i].created_ms < call_expiry_ms) { ++i; continue; }
    const int ref = calls_[i].ref;
    calls_[i] = calls_[--call_count_];
    lua_rawgeti(L, LUA_REGISTRYINDEX, ref);
    luaL_unref(L, LUA_REGISTRYINDEX, ref);
    lua_pushboolean(L, 0);
    lua_pushstring(L, "no answer from Jarvis (timed out)");
    if (lua_pcall(L, 2, 0, 0) != LUA_OK) { report_error(L, "jarvis callback"); return; }
  }
}

// Queues a synthetic jarvis_result so the callback fires on the event loop.
void ScriptRuntime::fail_call_locally(uint16_t id, const char* reason) {
  proto::FrameBuilder fb;
  fb.begin(static_cast<uint8_t>(proto::Op::jarvis_result));
  fb.push_u16(id);
  fb.push(0);
  fb.push_bytes(reinterpret_cast<const uint8_t*>(reason), strlen(reason));
  const size_t n = fb.finish();
  if (n) deliver_event(fb.data(), n);
}

void ScriptRuntime::handle_event(lua_State* L, const Frame& f) {
  proto::Request req{};
  if (proto::decode(f.bytes, f.len, req) != proto::Status::ok) return;
  if (req.op == static_cast<uint8_t>(proto::Event::input_changed)) {
    if (req.payload_len < 2) return;
    const uint8_t gpio = req.payload[0];
    if (gpio >= max_gpio || input_refs_[gpio] == LUA_NOREF) return;
    lua_rawgeti(L, LUA_REGISTRYINDEX, input_refs_[gpio]);
    lua_pushinteger(L, req.payload[1]);
    if (lua_pcall(L, 1, 0, 0) != LUA_OK) report_error(L, "on_input");
    return;
  }
  if (req.op == static_cast<uint8_t>(proto::Op::jarvis_result)) {
    // call_id (u16), ok, text…
    if (req.payload_len < 3) return;
    const uint16_t id = static_cast<uint16_t>((req.payload[0] << 8) | req.payload[1]);
    for (size_t i = 0; i < call_count_; ++i) {
      if (calls_[i].id != id) continue;
      const int ref = calls_[i].ref;
      calls_[i] = calls_[--call_count_];
      lua_rawgeti(L, LUA_REGISTRYINDEX, ref);
      luaL_unref(L, LUA_REGISTRYINDEX, ref);
      lua_pushboolean(L, req.payload[2] != 0);
      lua_pushlstring(L, reinterpret_cast<const char*>(req.payload + 3), req.payload_len - 3);
      if (lua_pcall(L, 2, 0, 0) != LUA_OK) report_error(L, "jarvis callback");
      return;
    }
  }
}

void ScriptRuntime::run_timers(lua_State* L, uint32_t now) {
  for (size_t i = 0; i < timer_count_;) {
    Timer& t = timers_[i];
    if (static_cast<int32_t>(now - t.due_ms) < 0) { ++i; continue; }
    lua_rawgeti(L, LUA_REGISTRYINDEX, t.ref);
    if (lua_pcall(L, 0, 0, 0) != LUA_OK) { report_error(L, "timer"); return; }
    if (t.period_ms == 0) {
      luaL_unref(L, LUA_REGISTRYINDEX, t.ref);
      timers_[i] = timers_[--timer_count_];
    } else {
      t.due_ms = now + t.period_ms;
      ++i;
    }
  }
}

// A script command is a frame through loop(), like the phone's. Blocks the Lua task
// until the reply arrives (or the timeout); loop() keeps running meanwhile.
bool ScriptRuntime::call(proto::Op op, const uint8_t* payload, size_t len, Frame& reply, uint32_t timeout_ms) {
  proto::FrameBuilder fb;
  fb.begin(static_cast<uint8_t>(op));
  fb.push_bytes(payload, len);
  const size_t n = fb.finish();
  if (n == 0) return false;
  Frame f;
  f.len = static_cast<uint8_t>(n);
  memcpy(f.bytes, fb.data(), n);
  xQueueReset(reply_queue_);
  if (xQueueSend(cmd_queue_, &f, pdMS_TO_TICKS(100)) != pdTRUE) return false;
  return xQueueReceive(reply_queue_, &reply, pdMS_TO_TICKS(timeout_ms)) == pdTRUE;
}

// ───────────────────────────── Lua API ─────────────────────────────

int ScriptRuntime::l_gpio_mode(lua_State* L) {
  const int pin = check_pin(L, 1);
  const char* mode = luaL_checkstring(L, 2);
  uint8_t m = 0;
  if (!strcmp(mode, "output")) m = 1;
  else if (!strcmp(mode, "input")) m = 2;
  else if (!strcmp(mode, "input_pullup")) m = 3;
  else if (!strcmp(mode, "input_pulldown")) m = 4;
  else if (!strcmp(mode, "pwm")) m = 5;
  else return luaL_error(L, "unknown mode '%s'", mode);
  RUN_COMMAND(L, proto::Op::pin_mode, static_cast<uint8_t>(pin), m);
  return 0;
}

int ScriptRuntime::l_gpio_write(lua_State* L) {
  const int pin = check_pin(L, 1);
  const int level = check_level(L, 2);
  RUN_COMMAND(L, proto::Op::pin_write, static_cast<uint8_t>(pin), static_cast<uint8_t>(level));
  return 0;
}

int ScriptRuntime::l_gpio_read(lua_State* L) {
  const int pin = check_pin(L, 1);
  RUN_COMMAND(L, proto::Op::pin_read, static_cast<uint8_t>(pin));
  lua_pushinteger(L, r_.payload_len >= 2 ? r_.payload[1] : 0);
  return 1;
}

int ScriptRuntime::l_gpio_pwm(lua_State* L) {
  const int pin = check_pin(L, 1);
  const lua_Integer duty = luaL_checkinteger(L, 2);
  if (duty < 0 || duty > 255) return luaL_error(L, "duty must be 0-255");
  RUN_COMMAND(L, proto::Op::pin_pwm, static_cast<uint8_t>(pin), static_cast<uint8_t>(duty));
  return 0;
}

int ScriptRuntime::l_gpio_pulse(lua_State* L) {
  const int pin = check_pin(L, 1);
  const int level = check_level(L, 2);
  const lua_Integer ms = luaL_checkinteger(L, 3);
  if (ms < 1 || ms > cfg::max_pulse_ms) return luaL_error(L, "duration must be 1-%d ms", static_cast<int>(cfg::max_pulse_ms));
  RUN_COMMAND(L, proto::Op::pin_pulse, static_cast<uint8_t>(pin), static_cast<uint8_t>(level),
              static_cast<uint8_t>(ms >> 8), static_cast<uint8_t>(ms & 0xFF));
  return 0;
}

int ScriptRuntime::l_led_set(lua_State* L) {
  const int level = check_level(L, 1);
  RUN_COMMAND(L, proto::Op::led_set, static_cast<uint8_t>(level));
  return 0;
}

int ScriptRuntime::l_led_blink(lua_State* L) {
  const lua_Integer count = luaL_optinteger(L, 1, 3);
  const lua_Integer period = luaL_optinteger(L, 2, 300);
  if (count < 0 || count > 255) return luaL_error(L, "count must be 0-255");
  RUN_COMMAND(L, proto::Op::led_blink, static_cast<uint8_t>(count),
              static_cast<uint8_t>(period >> 8), static_cast<uint8_t>(period & 0xFF));
  return 0;
}

int ScriptRuntime::l_on_input(lua_State* L) {
  const int pin = check_pin(L, 1);
  luaL_checktype(L, 2, LUA_TFUNCTION);
  ScriptRuntime* rt = self(L);
  if (rt->input_refs_[pin] != LUA_NOREF) luaL_unref(L, LUA_REGISTRYINDEX, rt->input_refs_[pin]);
  lua_pushvalue(L, 2);
  rt->input_refs_[pin] = luaL_ref(L, LUA_REGISTRYINDEX);
  return 0;
}

int ScriptRuntime::l_every(lua_State* L) {
  const lua_Integer ms = luaL_checkinteger(L, 1);
  luaL_checktype(L, 2, LUA_TFUNCTION);
  if (ms < 10) return luaL_error(L, "period must be at least 10 ms");
  ScriptRuntime* rt = self(L);
  if (rt->timer_count_ >= max_timers) return luaL_error(L, "too many timers");
  lua_pushvalue(L, 2);
  rt->timers_[rt->timer_count_++] = Timer{millis() + static_cast<uint32_t>(ms), static_cast<uint32_t>(ms),
                                          luaL_ref(L, LUA_REGISTRYINDEX)};
  return 0;
}

int ScriptRuntime::l_after(lua_State* L) {
  const lua_Integer ms = luaL_checkinteger(L, 1);
  luaL_checktype(L, 2, LUA_TFUNCTION);
  if (ms < 0) return luaL_error(L, "delay must be positive");
  ScriptRuntime* rt = self(L);
  if (rt->timer_count_ >= max_timers) return luaL_error(L, "too many timers");
  lua_pushvalue(L, 2);
  rt->timers_[rt->timer_count_++] = Timer{millis() + static_cast<uint32_t>(ms), 0, luaL_ref(L, LUA_REGISTRYINDEX)};
  return 0;
}

int ScriptRuntime::l_sleep_ms(lua_State* L) {
  lua_Integer ms = luaL_checkinteger(L, 1);
  ScriptRuntime* rt = self(L);
  while (ms > 0 && !rt->stop_requested_) {
    const lua_Integer slice = ms < 50 ? ms : 50;
    vTaskDelay(pdMS_TO_TICKS(slice));
    ms -= slice;
  }
  if (rt->stop_requested_) return luaL_error(L, "stopped");
  return 0;
}

int ScriptRuntime::l_millis(lua_State* L) {
  lua_pushinteger(L, static_cast<lua_Integer>(millis()));
  return 1;
}

int ScriptRuntime::l_print(lua_State* L) {
  const int n = lua_gettop(L);
  String line;
  for (int i = 1; i <= n; ++i) {
    size_t len = 0;
    const char* s = luaL_tolstring(L, i, &len);
    if (i > 1) line += '\t';
    line += s;
    lua_pop(L, 1);
  }
  self(L)->emit_output(line.c_str());
  return 0;
}

// jarvis.invoke(name, args_table [, callback]) — raises a jarvis_call event the phone
// relays to Jarvis; the answer (if any) comes back through jarvis_result.
int ScriptRuntime::l_jarvis_invoke(lua_State* L) {
  const char* name = luaL_checkstring(L, 1);
  String json = "{}";
  if (lua_istable(L, 2)) { json = ""; json_table(L, 2, json, 0); }
  ScriptRuntime* rt = self(L);
  uint16_t id = rt->next_call_id_++;
  if (rt->next_call_id_ == 0) rt->next_call_id_ = 1;
  const bool has_callback = lua_isfunction(L, 3);
  if (has_callback) {
    if (rt->call_count_ >= max_calls) {
      // Never let a chatty script kill itself: drop the oldest wait instead.
      luaL_unref(L, LUA_REGISTRYINDEX, rt->calls_[0].ref);
      rt->calls_[0] = rt->calls_[--rt->call_count_];
    }
    lua_pushvalue(L, 3);
    rt->calls_[rt->call_count_++] = PendingCall{id, luaL_ref(L, LUA_REGISTRYINDEX), millis()};
  }
  // Nothing listening: the phone is away and the board has no bridge of its own.
  // Answer the callback right away rather than parking the call.
  if (rt->has_link_ && !rt->has_link_()) {
    if (has_callback) rt->fail_call_locally(id, "no link to Jarvis right now");
    lua_pushinteger(L, id);
    return 1;
  }
  const size_t name_len = strlen(name) > 40 ? 40 : strlen(name);
  const size_t room = proto::max_body - 1 - 2 - 1 - name_len;
  if (json.length() > room) return luaL_error(L, "jarvis.invoke arguments too long (%d bytes max)", static_cast<int>(room));
  proto::FrameBuilder fb;
  fb.begin_event(proto::Event::jarvis_call);
  fb.push_u16(id);
  fb.push_string(name, 40);
  fb.push_bytes(reinterpret_cast<const uint8_t*>(json.c_str()), json.length());
  const size_t n = fb.finish();
  if (n == 0) return luaL_error(L, "jarvis.invoke frame too long");
  if (rt->emit_) rt->emit_(fb.data(), n);
  lua_pushinteger(L, id);
  return 1;
}

int ScriptRuntime::l_jarvis_notify(lua_State* L) {
  const char* title = luaL_checkstring(L, 1);
  const char* body = luaL_optstring(L, 2, "");
  lua_settop(L, 0);
  lua_pushstring(L, "notify");
  lua_newtable(L);
  lua_pushstring(L, title); lua_setfield(L, -2, "title");
  lua_pushstring(L, body); lua_setfield(L, -2, "body");
  return l_jarvis_invoke(L);
}

int ScriptRuntime::l_wifi_status(lua_State* L) {
  RUN_COMMAND(L, proto::Op::wifi_status);
  // status, state, ip[4], rssi, port[2], host_len, host…, ssid_len, ssid…
  lua_newtable(L);
  if (r_.payload_len >= 9) {
    const uint8_t* p = r_.payload + 1;
    const size_t plen = r_.payload_len - 1;
    static const char* names[] = {"off", "connecting", "connected", "failed"};
    lua_pushstring(L, p[0] < 4 ? names[p[0]] : "unknown"); lua_setfield(L, -2, "state");
    char ip[20];
    snprintf(ip, sizeof(ip), "%u.%u.%u.%u", p[1], p[2], p[3], p[4]);
    lua_pushstring(L, ip); lua_setfield(L, -2, "ip");
    lua_pushinteger(L, static_cast<int8_t>(p[5])); lua_setfield(L, -2, "rssi");
    size_t cur = 8;
    if (cur < plen) {
      const size_t hl = p[cur]; cur += 1;
      if (cur + hl <= plen) {
        lua_pushlstring(L, reinterpret_cast<const char*>(p + cur), hl); lua_setfield(L, -2, "hostname");
        cur += hl;
        if (cur < plen) {
          const size_t sl = p[cur]; cur += 1;
          if (cur + sl <= plen) {
            lua_pushlstring(L, reinterpret_cast<const char*>(p + cur), sl); lua_setfield(L, -2, "ssid");
          }
        }
      }
    }
  }
  return 1;
}

void ScriptRuntime::open_api(lua_State* L) {
  static const luaL_Reg gpio[] = {
    {"mode", l_gpio_mode}, {"write", l_gpio_write}, {"read", l_gpio_read},
    {"pwm", l_gpio_pwm}, {"pulse", l_gpio_pulse}, {nullptr, nullptr}};
  static const luaL_Reg led[] = {{"set", l_led_set}, {"blink", l_led_blink}, {nullptr, nullptr}};
  static const luaL_Reg jarvis[] = {{"invoke", l_jarvis_invoke}, {"notify", l_jarvis_notify}, {nullptr, nullptr}};
  static const luaL_Reg wifi[] = {{"status", l_wifi_status}, {nullptr, nullptr}};
  luaL_newlib(L, gpio); lua_setglobal(L, "gpio");
  luaL_newlib(L, led); lua_setglobal(L, "led");
  luaL_newlib(L, jarvis); lua_setglobal(L, "jarvis");
  luaL_newlib(L, wifi); lua_setglobal(L, "wifi");
  lua_register(L, "on_input", l_on_input);
  lua_register(L, "every", l_every);
  lua_register(L, "after", l_after);
  lua_register(L, "sleep_ms", l_sleep_ms);
  lua_register(L, "millis", l_millis);
  lua_register(L, "print", l_print);
}

}  // namespace jarvis
