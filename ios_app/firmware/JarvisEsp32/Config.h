// Build-time settings for the Jarvis ESP32 firmware. Everything the app depends on
// (UUIDs, opcodes, framing) lives in Protocol.h and must not be changed without
// changing Esp32Protocol.swift to match. This file is the safe place to tweak.
#ifndef JARVIS_ESP32_CONFIG_H
#define JARVIS_ESP32_CONFIG_H

#include <stdint.h>

namespace jarvis::config {

// Advertised as "<prefix>-XXXX" where XXXX is the last two bytes of the BLE MAC, so
// two boards on the same desk stay distinguishable. The app matches on the prefix.
constexpr const char* device_name_prefix = "Jarvis-ESP32";

// Pairing is "Just Works": the board has no display or keypad, so no passkey. The link
// is still encrypted and bonded; iOS shows a plain Pair/Cancel prompt once per phone.

constexpr uint8_t firmware_major = 1;
constexpr uint8_t firmware_minor = 0;

// Hold the onboard LED steady on while a phone is connected and blink it slowly while
// advertising. Set false to keep the LED strictly under app control.
constexpr bool led_shows_link_state = true;

// How often input pins are sampled for change events, and how long a level must hold
// before it counts as a real edge rather than bounce.
constexpr uint32_t input_poll_ms = 10;
constexpr uint32_t input_debounce_ms = 40;

// Upper bound on any single timed action so a typo can't park a pin high for an hour.
constexpr uint16_t max_pulse_ms = 10000;
constexpr uint16_t max_blink_period_ms = 5000;
constexpr uint16_t min_blink_period_ms = 50;

constexpr uint32_t serial_baud = 115200;

}  // namespace jarvis::config

#endif  // JARVIS_ESP32_CONFIG_H
