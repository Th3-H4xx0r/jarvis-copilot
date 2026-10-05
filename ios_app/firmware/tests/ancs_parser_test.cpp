// Host test for JarvisEsp32/AncsParser.h — runs on the Mac, no board needed:
//   c++ -std=c++17 -Wall -Wextra -I../JarvisEsp32 ancs_parser_test.cpp -o /tmp/ancs_test && /tmp/ancs_test
#include "AncsParser.h"

#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

using namespace jarvis::ancs;

static int failures = 0;
#define CHECK(cond) do { if (!(cond)) { std::printf("FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond); ++failures; } } while (0)

static void attr(std::vector<uint8_t>& v, uint8_t id, const char* s) {
  const size_t n = std::strlen(s);
  v.push_back(id);
  v.push_back(static_cast<uint8_t>(n));
  v.push_back(static_cast<uint8_t>(n >> 8));
  v.insert(v.end(), s, s + n);
}

static std::vector<uint8_t> reply(uint32_t uid, const char* app, const char* title, const char* msg) {
  std::vector<uint8_t> v = {command_get_notification_attributes,
                            uint8_t(uid), uint8_t(uid >> 8), uint8_t(uid >> 16), uint8_t(uid >> 24)};
  attr(v, attr_app_identifier, app);
  attr(v, attr_title, title);
  attr(v, attr_message, msg);
  return v;
}

int main() {
  // UUID string → Bluedroid's little-endian bytes (first string byte ends up last).
  uint8_t u[16];
  CHECK(uuid128_le(service_uuid, u));
  const uint8_t ancs_le[16] = {0xD0, 0x00, 0x2D, 0x12, 0x1E, 0x4B, 0x0F, 0xA4,
                               0x99, 0x4E, 0xCE, 0xB5, 0x31, 0xF4, 0x05, 0x79};
  CHECK(std::memcmp(u, ancs_le, 16) == 0);
  CHECK(!uuid128_le("7905F431-B5CE", u));
  CHECK(!uuid128_le("ZZ05F431-B5CE-4E99-A40F-4B1E122D00D0", u));

  // Notification Source: only new, non-replayed notifications are wanted.
  const uint8_t added[8] = {0, 0x02, 4, 1, 0x78, 0x56, 0x34, 0x12};
  SourceEvent e{};
  CHECK(parse_source(added, 8, e));
  CHECK(e.uid == 0x12345678 && e.category == 4 && wants(e));
  const uint8_t replayed[8] = {0, flag_pre_existing, 4, 1, 1, 0, 0, 0};
  CHECK(parse_source(replayed, 8, e) && !wants(e));
  const uint8_t removed[8] = {2, 0, 4, 0, 1, 0, 0, 0};
  CHECK(parse_source(removed, 8, e) && !wants(e));
  CHECK(!parse_source(added, 7, e));

  // Get Notification Attributes request: command, uid LE, app id, title+max, message+max.
  uint8_t req[request_len];
  CHECK(build_request(0x01020304, req) == request_len);
  const uint8_t want_req[request_len] = {0, 4, 3, 2, 1, 0, 1, 64, 0, 3, 160, 0};
  CHECK(std::memcmp(req, want_req, request_len) == 0);

  // Whole reply in one notification.
  Assembler a;
  auto r = reply(7, "com.apple.MobileSMS", "Mom", "Dinner at 7?");
  a.begin(7);
  CHECK(a.feed(r.data(), r.size()) == Assembler::Result::done);
  CHECK(std::strcmp(a.attributes().app, "com.apple.MobileSMS") == 0);
  CHECK(std::strcmp(a.attributes().title, "Mom") == 0);
  CHECK(std::strcmp(a.attributes().message, "Dinner at 7?") == 0);

  // Same reply split at awkward points (mid-header, mid-length, mid-value).
  a.begin(7);
  CHECK(a.feed(r.data(), 3) == Assembler::Result::more);
  CHECK(a.feed(r.data() + 3, 5) == Assembler::Result::more);
  CHECK(a.feed(r.data() + 8, 20) == Assembler::Result::more);
  CHECK(a.feed(r.data() + 28, r.size() - 28) == Assembler::Result::done);
  CHECK(std::strcmp(a.attributes().message, "Dinner at 7?") == 0);

  // Empty title is still a complete reply.
  r = reply(9, "com.slack", "", "hi");
  a.begin(9);
  CHECK(a.feed(r.data(), r.size()) == Assembler::Result::done);
  CHECK(a.attributes().title[0] == '\0');

  // A reply for a different notification (a late answer) is rejected.
  r = reply(8, "x", "y", "z");
  a.begin(9);
  CHECK(a.feed(r.data(), r.size()) == Assembler::Result::error);

  // An over-long app id is clipped, NUL-terminated, not overflowed.
  std::string longapp(200, 'a');
  r = reply(5, longapp.c_str(), "t", "m");
  a.begin(5);
  CHECK(a.feed(r.data(), r.size()) == Assembler::Result::done);
  CHECK(std::strlen(a.attributes().app) == max_app);

  // UTF-8 clipping backs off to a character boundary ("é" is 2 bytes).
  const char* s = "abc\xC3\xA9";
  CHECK(utf8_fit(s, 5, 4) == 3);
  CHECK(utf8_fit(s, 5, 5) == 5);
  CHECK(utf8_fit(s, 5, 10) == 5);

  // A reply bigger than the buffer errors instead of overflowing.
  std::vector<uint8_t> huge(600, 0);
  a.begin(1);
  CHECK(a.feed(huge.data(), huge.size()) == Assembler::Result::error);

  if (failures == 0) std::printf("ancs_parser_test: all passed\n");
  return failures == 0 ? 0 : 1;
}
