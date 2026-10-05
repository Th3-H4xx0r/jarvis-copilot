// Apple Notification Center Service (ANCS) wire format — the parts the notification
// relay needs. Plain C++ with no ESP-IDF dependency, so `firmware/tests/ancs_parser_test.cpp`
// builds it on a Mac. Spec: Apple, "Apple Notification Center Service (ANCS) Specification".
#ifndef JARVIS_ESP32_ANCS_PARSER_H
#define JARVIS_ESP32_ANCS_PARSER_H

#include <stdint.h>
#include <stddef.h>
#include <string.h>

namespace jarvis::ancs {

constexpr const char* service_uuid             = "7905F431-B5CE-4E99-A40F-4B1E122D00D0";
constexpr const char* notification_source_uuid = "9FBF120D-6301-42D9-8C58-25E699A21DBD";
constexpr const char* control_point_uuid       = "69D1D8F3-45E1-49A8-9821-9BBDFDAAD9D9";
constexpr const char* data_source_uuid         = "22EAC6E9-24D6-4BB5-BE44-B36ACE7C7BFB";

constexpr uint8_t event_added = 0;
constexpr uint8_t flag_pre_existing = 1 << 2;
constexpr uint8_t command_get_notification_attributes = 0;
constexpr uint8_t attr_app_identifier = 0;
constexpr uint8_t attr_title = 1;
constexpr uint8_t attr_message = 3;

// Longest values the relay asks iOS for. The event frame to the phone clips them further.
constexpr uint16_t max_title = 64;
constexpr uint16_t max_message = 160;
constexpr size_t max_app = 64;
constexpr size_t request_len = 12;  // command, uid[4], app id, title+max[2], message+max[2]

/// "7905F431-…" → the 16 little-endian bytes Bluedroid's esp_bt_uuid_t wants.
inline bool uuid128_le(const char* s, uint8_t out[16]) {
  int n = 0;
  for (const char* p = s; *p != '\0'; ++p) {
    if (*p == '-') continue;
    int v;
    if (*p >= '0' && *p <= '9') v = *p - '0';
    else if (*p >= 'a' && *p <= 'f') v = *p - 'a' + 10;
    else if (*p >= 'A' && *p <= 'F') v = *p - 'A' + 10;
    else return false;
    if (n >= 32) return false;
    uint8_t& b = out[15 - n / 2];
    b = (n % 2 == 0) ? static_cast<uint8_t>(v << 4) : static_cast<uint8_t>(b | v);
    ++n;
  }
  return n == 32;
}

inline uint32_t read_u32_le(const uint8_t* p) {
  return uint32_t(p[0]) | uint32_t(p[1]) << 8 | uint32_t(p[2]) << 16 | uint32_t(p[3]) << 24;
}

/// One Notification Source event (8 bytes).
struct SourceEvent {
  uint8_t event_id;
  uint8_t flags;
  uint8_t category;
  uint8_t category_count;
  uint32_t uid;
};

inline bool parse_source(const uint8_t* p, size_t n, SourceEvent& e) {
  if (n < 8) return false;
  e = SourceEvent{p[0], p[1], p[2], p[3], read_u32_le(p + 4)};
  return true;
}

/// A notification worth reading: newly added, not one iOS replays when we subscribe.
inline bool wants(const SourceEvent& e) {
  return e.event_id == event_added && (e.flags & flag_pre_existing) == 0;
}

/// Get Notification Attributes for the app identifier, title and message.
inline size_t build_request(uint32_t uid, uint8_t out[request_len]) {
  size_t i = 0;
  out[i++] = command_get_notification_attributes;
  for (int b = 0; b < 4; ++b) out[i++] = static_cast<uint8_t>(uid >> (8 * b));
  out[i++] = attr_app_identifier;
  out[i++] = attr_title;
  out[i++] = static_cast<uint8_t>(max_title);
  out[i++] = static_cast<uint8_t>(max_title >> 8);
  out[i++] = attr_message;
  out[i++] = static_cast<uint8_t>(max_message);
  out[i++] = static_cast<uint8_t>(max_message >> 8);
  return i;
}

/// Length of the longest prefix of `s` (length `n`) that fits in `max` bytes without
/// cutting a UTF-8 sequence in half.
inline size_t utf8_fit(const char* s, size_t n, size_t max) {
  if (n <= max) return n;
  n = max;
  while (n > 0 && (static_cast<uint8_t>(s[n]) & 0xC0) == 0x80) --n;
  return n;
}

/// One notification's attributes, NUL-terminated.
struct Attributes {
  char app[max_app + 1];
  char title[max_title + 1];
  char message[max_message + 1];
};

/// Reassembles a Get Notification Attributes reply from Data Source notifications, which
/// iOS splits at the ATT MTU. Done once all three requested attributes have arrived.
class Assembler {
 public:
  enum class Result { more, done, error };

  void begin(uint32_t uid) { uid_ = uid; len_ = 0; }

  Result feed(const uint8_t* p, size_t n) {
    if (len_ + n > sizeof(buf_)) { len_ = 0; return Result::error; }
    memcpy(buf_ + len_, p, n);
    len_ += n;
    return parse();
  }

  const Attributes& attributes() const { return out_; }

 private:
  Result parse() {
    if (len_ < 5) return Result::more;
    if (buf_[0] != command_get_notification_attributes || read_u32_le(buf_ + 1) != uid_) return Result::error;
    out_ = Attributes{};
    uint8_t seen = 0;
    size_t i = 5;
    while (i + 3 <= len_) {
      const uint8_t id = buf_[i];
      const size_t vlen = size_t(buf_[i + 1]) | size_t(buf_[i + 2]) << 8;
      if (i + 3 + vlen > len_) return Result::more;
      const char* v = reinterpret_cast<const char*>(buf_ + i + 3);
      if (id == attr_app_identifier) { copy(out_.app, sizeof(out_.app), v, vlen); seen |= 1; }
      else if (id == attr_title)     { copy(out_.title, sizeof(out_.title), v, vlen); seen |= 2; }
      else if (id == attr_message)   { copy(out_.message, sizeof(out_.message), v, vlen); seen |= 4; }
      i += 3 + vlen;
    }
    return seen == 7 ? Result::done : Result::more;
  }

  static void copy(char* dst, size_t cap, const char* src, size_t n) {
    n = utf8_fit(src, n, cap - 1);
    memcpy(dst, src, n);
    dst[n] = '\0';
  }

  uint8_t buf_[512] = {};
  size_t len_ = 0;
  uint32_t uid_ = 0;
  Attributes out_ = {};
};

}  // namespace jarvis::ancs

#endif  // JARVIS_ESP32_ANCS_PARSER_H
