// Host test for PcButton.h: the power-light classifier and press rules (no board needed).
//   ./run_pc_button_test.sh
#include <cassert>
#include <cstdint>
#include <cstdio>
#include <string_view>

#include "PcButton.h"

using namespace jarvis::pcbutton;

namespace {

// Feeds one sample every 20 ms from start for ms; returns the time after the last one.
uint32_t feed(LightClassifier& c, uint32_t start, uint32_t ms, bool lit) {
  uint32_t t = start;
  for (; t < start + ms; t += 20) c.sample(t, lit);
  return t;
}

uint32_t blink(LightClassifier& c, uint32_t start, uint32_t ms) {
  uint32_t t = start;
  while (t < start + ms) {
    t = feed(c, t, 500, true);
    t = feed(c, t, 500, false);
  }
  return t;
}

void starts_unknown() {
  LightClassifier c;
  feed(c, 0, 1000, true);
  assert(c.state() == Light::unknown);
}

void steady_lit_3s_is_on() {
  LightClassifier c;
  feed(c, 0, 3100, true);
  assert(c.state() == Light::on);
}

void steady_dark_3s_is_off() {
  LightClassifier c;
  feed(c, 0, 3100, false);
  assert(c.state() == Light::off);
}

void blink_is_asleep() {
  LightClassifier c;
  uint32_t t = blink(c, 0, 4000);
  assert(c.state() == Light::asleep);
  feed(c, t, 3100, true);
  assert(c.state() == Light::on);
}

void lit_from_mv_either_topology() {
  assert(lit_from_mv(2400, 0));      // high side switched
  assert(!lit_from_mv(2400, 2350));  // low side, LED off: both ends high
  assert(lit_from_mv(2400, 300));    // low side, LED on
  assert(!lit_from_mv(0, 0));
}

void expect_rules() {
  const char* on[] = {"on"};
  const char* waking[] = {"asleep", "off", "unknown"};
  const char* any[] = {"any"};
  assert(!expect_allows(on, 1, Light::asleep));
  assert(expect_allows(on, 1, Light::on));
  assert(expect_allows(waking, 3, Light::unknown));
  assert(!expect_allows(waking, 3, Light::on));
  assert(expect_allows(any, 1, Light::on));
  assert(expect_allows(any, 1, Light::unknown));
  assert(!expect_allows(nullptr, 0, Light::on));
}

void press_bounds() {
  Hold h{};
  assert(hold_start(h, 0, 19) == PressError::bad_ms);
  assert(hold_start(h, 0, 10001) == PressError::bad_ms);
  assert(!h.held);
  assert(hold_start(h, 0, 300) == PressError::none);
  assert(h.held);
  assert(hold_start(h, 10, 300) == PressError::busy);
}

void press_survives_without_link() {
  Hold h{};
  const uint32_t t0 = 0xFFFFF000u;  // millis() wraps during the hold
  assert(hold_start(h, t0, 6000) == PressError::none);
  assert(!hold_due(h, t0 + 5999));
  assert(hold_due(h, t0 + 6000));
}

void light_names() {
  assert(std::string_view(light_name(Light::asleep)) == "asleep");
  assert(std::string_view(light_name(Light::unknown)) == "unknown");
}

}  // namespace

int main() {
  starts_unknown();
  steady_lit_3s_is_on();
  steady_dark_3s_is_off();
  blink_is_asleep();
  lit_from_mv_either_topology();
  expect_rules();
  press_bounds();
  press_survives_without_link();
  light_names();
  std::puts("all pc_button tests passed");
  return 0;
}
