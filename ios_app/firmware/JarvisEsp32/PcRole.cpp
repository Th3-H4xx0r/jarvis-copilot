#include "PcRole.h"

#include <Preferences.h>

namespace jarvis {

namespace {
constexpr const char* prefs_ns = "jarvis";
constexpr const char* key_role = "pcrole";
constexpr uint32_t sample_every_ms = 20;
constexpr uint32_t report_every_ms = 60000;
constexpr uint32_t retry_every_ms = 2000;
}  // namespace

const char* PcRole::catalogue() {
  return R"JSON({"name":"esp32_pc_power_state","description":"The PC power button board: the PC's power light (on, asleep, off, unknown), how long it has been that way, the raw LED pin millivolts, and whether a button is being held.","input_schema":{"type":"object","properties":{}}},
{"name":"esp32_pc_press","description":"Press the PC's power or reset button for ms milliseconds. Refuses unless the power light is in expect (or expect has any).","input_schema":{"type":"object","properties":{"button":{"type":"string","enum":["power","reset"]},"ms":{"type":"integer","minimum":20,"maximum":10000,"default":300},"expect":{"type":"array","items":{"type":"string","enum":["on","asleep","off","unknown","any"]}}},"required":["button","expect"]}})JSON";
}

void PcRole::begin(EventSink sink) {
  pinMode(power_gpio, INPUT);  // both buttons up before anything else runs
  pinMode(reset_gpio, INPUT);
  sink_ = std::move(sink);
  Preferences prefs;
  if (prefs.begin(prefs_ns, /*readOnly=*/true)) {
    on_ = prefs.isKey(key_role) && prefs.getBool(key_role, false);
    prefs.end();
  }
  if (on_) {
    pinMode(led_plus_gpio, INPUT);
    pinMode(led_minus_gpio, INPUT);
    Serial.println("[pc] PC power button role on");
  }
}

bool PcRole::reserved(uint8_t gpio) const {
  return on_ && (gpio == power_gpio || gpio == reset_gpio || gpio == led_plus_gpio || gpio == led_minus_gpio);
}

bool PcRole::set_on(bool on) {
  Preferences prefs;
  bool was = false;
  if (!prefs.begin(prefs_ns, /*readOnly=*/false)) return false;
  was = prefs.isKey(key_role) && prefs.getBool(key_role, false);
  prefs.putBool(key_role, on);
  prefs.end();
  return was != on;
}

void PcRole::release(pcbutton::Hold& h, uint8_t gpio) {
  pinMode(gpio, INPUT);  // high impedance: the motherboard's pull-up wins, button up
  pcbutton::hold_end(h);
}

String PcRole::light_json(uint32_t now) const {
  JsonDocument d;
  d["light"] = pcbutton::light_name(light_.state());
  d["since_s"] = light_.since_ms(now) / 1000;
  d["plus_mv"] = plus_mv_;
  d["minus_mv"] = minus_mv_;
  String out;
  serializeJson(d, out);
  return out;
}

void PcRole::service(uint32_t now) {
  if (pcbutton::hold_due(power_, now)) release(power_, power_gpio);
  if (pcbutton::hold_due(reset_, now)) release(reset_, reset_gpio);
  if (!on_) return;
  if (static_cast<int32_t>(now - next_sample_ms_) >= 0) {
    next_sample_ms_ = now + sample_every_ms;
    plus_mv_ = analogReadMilliVolts(led_plus_gpio);
    minus_mv_ = analogReadMilliVolts(led_minus_gpio);
    light_.sample(now, pcbutton::lit_from_mv(plus_mv_, minus_mv_));
  }
  const bool changed = !sent_once_ || light_.state() != sent_;
  const bool due = changed || now - sent_at_ms_ >= report_every_ms;
  if (!due || !sink_ || static_cast<int32_t>(now - retry_at_ms_) < 0) return;
  if (sink_("pc_power_light", light_json(now))) {
    sent_ = light_.state();
    sent_at_ms_ = now;
    sent_once_ = true;
  } else {
    retry_at_ms_ = now + retry_every_ms;  // bridge down: try again shortly
  }
}

bool PcRole::run_skill(const String& name, JsonVariantConst args, JsonDocument& result, String& error) {
  if (!on_) { error = "the PC power button role is off"; return false; }
  const uint32_t now = millis();
  if (name == "esp32_pc_power_state") {
    result["light"] = pcbutton::light_name(light_.state());
    result["since_s"] = light_.since_ms(now) / 1000;
    result["plus_mv"] = plus_mv_;
    result["minus_mv"] = minus_mv_;
    JsonObject held = result["held"].to<JsonObject>();
    held["power"] = power_.held;
    held["reset"] = reset_.held;
    return true;
  }
  if (name != "esp32_pc_press") { error = "unknown skill"; return false; }
  const String button = args["button"] | "";
  const bool is_power = button == "power";
  if (!is_power && button != "reset") { error = "button must be power or reset"; return false; }
  const uint32_t ms = args["ms"] | 300u;
  const char* expect[5] = {};
  size_t n = 0;
  for (JsonVariantConst v : args["expect"].as<JsonArrayConst>()) {
    if (n < 5 && v.is<const char*>()) expect[n++] = v.as<const char*>();
  }
  if (n == 0) { error = "expect is required"; return false; }
  const pcbutton::Light before = light_.state();
  if (!pcbutton::expect_allows(expect, n, before)) {
    error = String("the power light is ") + pcbutton::light_name(before) + ", so the press was refused";
    return false;
  }
  pcbutton::Hold& h = is_power ? power_ : reset_;
  const uint8_t gpio = is_power ? power_gpio : reset_gpio;
  switch (pcbutton::hold_start(h, now, ms)) {
    case pcbutton::PressError::bad_ms: error = "ms must be 20-10000"; return false;
    case pcbutton::PressError::busy: error = button + " is already being pressed"; return false;
    case pcbutton::PressError::none: break;
  }
  pinMode(gpio, OUTPUT_OPEN_DRAIN);
  digitalWrite(gpio, LOW);  // pull the signal to ground: button down
  Serial.printf("[pc] %s pressed for %lu ms (light %s)\n", button.c_str(), static_cast<unsigned long>(ms),
                pcbutton::light_name(before));
  result["ok"] = true;
  result["button"] = button;
  result["ms"] = ms;
  result["light_before"] = pcbutton::light_name(before);
  return true;
}

}  // namespace jarvis
