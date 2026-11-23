// The "PC power button" role: this board is wired to a PC's front-panel header and
// presses its power and reset buttons, and reads its power LED (see PcButton.h).
//
//   D26 -> 1 kOhm -> PANEL1 PWRBTN#     D25 -> 1 kOhm -> PANEL1 RESET#
//   PLED+ -> 10k -> GPIO 34 -> 10k -> GND    PLED- -> 10k -> GPIO 35 -> 10k -> GND
//
// Off by default; switched from the iPhone app over Bluetooth (op PC_ROLE) and applied
// after a reboot, so the skills catalogue and the reserved pins never change mid-session.
// While on, GPIO 25/26/34/35 are hidden from every generic pin command (BLE, Wi-Fi, Lua,
// cloud skills and all_off), and only the two server-only skills below reach them.
#ifndef JARVIS_ESP32_PC_ROLE_H
#define JARVIS_ESP32_PC_ROLE_H

#include <Arduino.h>
#include <ArduinoJson.h>
#include <functional>

#include "PcButton.h"

namespace jarvis {

class PcRole {
 public:
  using EventSink = std::function<bool(const char* name, const String& data_json)>;

  static constexpr uint8_t power_gpio = 26;
  static constexpr uint8_t reset_gpio = 25;
  static constexpr uint8_t led_plus_gpio = 34;
  static constexpr uint8_t led_minus_gpio = 35;

  /// Releases both buttons (first thing at boot), loads the role from NVS.
  void begin(EventSink sink);
  bool on() const { return on_; }
  /// True for a GPIO this role owns, while the role is on.
  bool reserved(uint8_t gpio) const;
  /// Saves the role for the next boot. True when it changed.
  bool set_on(bool on);
  /// Releases due presses, samples the light every 20 ms, reports changes.
  void service(uint32_t now);
  bool any_held() const { return power_.held || reset_.held; }
  /// esp32_pc_power_state / esp32_pc_press.
  bool run_skill(const String& name, JsonVariantConst args, JsonDocument& result, String& error);
  pcbutton::Light light() const { return light_.state(); }
  int plus_mv() const { return plus_mv_; }
  int minus_mv() const { return minus_mv_; }
  /// The two catalogue entries, comma-separated, for appending to the board's skills.
  static const char* catalogue();

 private:
  void release(pcbutton::Hold& h, uint8_t gpio);
  String light_json(uint32_t now) const;

  EventSink sink_;
  bool on_ = false;
  pcbutton::Hold power_{};
  pcbutton::Hold reset_{};
  pcbutton::LightClassifier light_;
  int plus_mv_ = 0;
  int minus_mv_ = 0;
  uint32_t next_sample_ms_ = 0;
  pcbutton::Light sent_ = pcbutton::Light::unknown;
  uint32_t sent_at_ms_ = 0;
  bool sent_once_ = false;
  uint32_t retry_at_ms_ = 0;
};

}  // namespace jarvis

#endif  // JARVIS_ESP32_PC_ROLE_H
