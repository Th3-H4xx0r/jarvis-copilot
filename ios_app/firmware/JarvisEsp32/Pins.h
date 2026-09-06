// GPIO map for the DOIT ESP32 DEVKIT V1 (30-pin) board.
//
// Only pins that are safe to drive from an app are listed. Deliberately absent:
//   GPIO 0        boot button / strapping, pulling it low at reset enters the bootloader
//   GPIO 1, 3     UART0 — the USB serial console
//   GPIO 6–11     the SPI flash; touching them crashes the chip
// Pins flagged `strapping` work normally at runtime but influence the boot mode if
// something external holds them at reset; the app shows a warning for those.
#ifndef JARVIS_ESP32_PINS_H
#define JARVIS_ESP32_PINS_H

#include <stdint.h>
#include <stddef.h>

namespace jarvis::pins {

// Capability bits reported per pin in GET_INFO. Mirrored in Esp32Protocol.swift.
enum class Capability : uint8_t {
  input     = 1u << 0,
  output    = 1u << 1,
  pwm       = 1u << 2,
  strapping = 1u << 3,
  led       = 1u << 4,  // the onboard blue LED hangs off this pin
};

constexpr uint8_t operator|(Capability a, Capability b) {
  return static_cast<uint8_t>(a) | static_cast<uint8_t>(b);
}
constexpr uint8_t operator|(uint8_t a, Capability b) {
  return a | static_cast<uint8_t>(b);
}
constexpr bool has(uint8_t flags, Capability c) {
  return (flags & static_cast<uint8_t>(c)) != 0;
}

struct Pin {
  uint8_t gpio;
  uint8_t flags;
};

constexpr uint8_t onboard_led_gpio = 2;

constexpr uint8_t io  = Capability::input | Capability::output | Capability::pwm;
constexpr uint8_t io_strap = io | Capability::strapping;
constexpr uint8_t in_only  = static_cast<uint8_t>(Capability::input);

// Order here is the order the app displays them in.
constexpr Pin table[] = {
  {2,  io_strap | Capability::led},
  {4,  io},
  {5,  io_strap},
  {12, io_strap},
  {13, io},
  {14, io},
  {15, io_strap},
  {16, io},
  {17, io},
  {18, io},
  {19, io},
  {21, io},
  {22, io},
  {23, io},
  {25, io},
  {26, io},
  {27, io},
  {32, io},
  {33, io},
  {34, in_only},
  {35, in_only},
  {36, in_only},
  {39, in_only},
};

constexpr size_t count = sizeof(table) / sizeof(table[0]);
static_assert(count <= 32, "GET_STATE frame must stay under one BLE MTU");

// Index into `table`, or -1 when the GPIO is not one we expose.
constexpr int index_of(uint8_t gpio) {
  for (size_t i = 0; i < count; ++i) {
    if (table[i].gpio == gpio) return static_cast<int>(i);
  }
  return -1;
}

static_assert(index_of(onboard_led_gpio) >= 0, "onboard LED must be in the table");
static_assert(index_of(6) < 0 && index_of(0) < 0 && index_of(1) < 0, "unsafe pins must stay out");

}  // namespace jarvis::pins

#endif  // JARVIS_ESP32_PINS_H
