// PC power button: the pure logic behind the pc_button role (JarvisEsp32.ino uses it).
// No Arduino includes, so tests/pc_button_test.cpp runs it on the Mac.
//
// The board presses the PC's front-panel buttons (open-drain: pull low or let go) and
// reads the power LED pins. ASRock B760M-CX manual p.30: the LED is steady while the PC
// runs, blinks in S1/S3 sleep, and is dark in S4/S5.
#ifndef JARVIS_ESP32_PC_BUTTON_H
#define JARVIS_ESP32_PC_BUTTON_H

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

namespace jarvis::pcbutton {

enum class Light : uint8_t { unknown = 0, on = 1, asleep = 2, off = 3 };

inline const char* light_name(Light l) {
  switch (l) {
    case Light::on: return "on";
    case Light::asleep: return "asleep";
    case Light::off: return "off";
    default: return "unknown";
  }
}

constexpr uint32_t steady_ms = 3000;   // lit or dark this long = on / off
constexpr uint32_t blink_window_ms = 4000;
constexpr uint8_t blink_transitions = 2;
constexpr int lit_threshold_mv = 1000;
constexpr uint32_t min_hold_ms = 20;
constexpr uint32_t max_hold_ms = 10000;

// The LED is lit when its two pins are far apart. That works whether the board switches
// the + side (PLED+ high, PLED- at ground) or the - side (PLED- pulled to ground).
inline bool lit_from_mv(int plus_mv, int minus_mv) { return abs(plus_mv - minus_mv) > lit_threshold_mv; }

class LightClassifier {
 public:
  void sample(uint32_t now, bool lit) {
    if (!started_) {
      started_ = true;
      lit_ = lit;
      changed_at_ = now;
      state_since_ = now;
    } else if (lit != lit_) {
      lit_ = lit;
      changed_at_ = now;
      edges_[head_] = now;
      head_ = (head_ + 1) % kEdges;
      if (count_ < kEdges) ++count_;
    }
    last_ = now;
    const Light next = classify();
    if (next != state_) {
      state_ = next;
      state_since_ = now;
    }
  }

  Light state() const { return state_; }
  uint32_t since_ms(uint32_t now) const { return now - state_since_; }

 private:
  static constexpr size_t kEdges = 16;

  Light classify() const {
    if (!started_) return Light::unknown;
    if (last_ - changed_at_ >= steady_ms) return lit_ ? Light::on : Light::off;
    uint8_t recent = 0;
    for (size_t i = 0; i < count_; ++i) {
      if (last_ - edges_[i] < blink_window_ms) ++recent;
    }
    return recent >= blink_transitions ? Light::asleep : Light::unknown;
  }

  bool started_ = false;
  bool lit_ = false;
  uint32_t changed_at_ = 0;
  uint32_t last_ = 0;
  uint32_t state_since_ = 0;
  Light state_ = Light::unknown;
  uint32_t edges_[kEdges] = {};
  size_t head_ = 0;
  size_t count_ = 0;
};

// "any" allows every state; otherwise the current light must be one of the names.
inline bool expect_allows(const char* const* expect, size_t n, Light current) {
  if (expect == nullptr) return false;
  for (size_t i = 0; i < n; ++i) {
    if (expect[i] == nullptr) continue;
    if (strcmp(expect[i], "any") == 0 || strcmp(expect[i], light_name(current)) == 0) return true;
  }
  return false;
}

enum class PressError : uint8_t { none, bad_ms, busy };

// One button's press. Released by time alone, so a hold finishes even if the link drops.
struct Hold {
  bool held;
  uint32_t until;
};

inline PressError hold_start(Hold& h, uint32_t now, uint32_t ms) {
  if (ms < min_hold_ms || ms > max_hold_ms) return PressError::bad_ms;
  if (h.held) return PressError::busy;
  h.held = true;
  h.until = now + ms;
  return PressError::none;
}

inline bool hold_due(const Hold& h, uint32_t now) { return h.held && static_cast<int32_t>(now - h.until) >= 0; }

inline void hold_end(Hold& h) { h.held = false; }

}  // namespace jarvis::pcbutton

#endif  // JARVIS_ESP32_PC_BUTTON_H
