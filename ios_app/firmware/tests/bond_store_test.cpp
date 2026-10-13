// Host test for JarvisEsp32/BondStore.h — runs on the Mac, no board needed:
//   c++ -std=c++17 -Wall -Wextra -I../JarvisEsp32 bond_store_test.cpp -o /tmp/bond_test && /tmp/bond_test
#include "BondStore.h"

#include <cstdio>
#include <cstring>
#include <map>
#include <string>
#include <vector>

using namespace jarvis::bonds;

static int failures = 0;
#define CHECK(cond) do { if (!(cond)) { std::printf("FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond); ++failures; } } while (0)

// An NVS namespace stand-in: key → blob.
using Store = std::map<std::string, std::vector<uint8_t>>;

static auto reader(const Store& s) {
  return [&s](const char* key, uint8_t* buf, size_t& len) -> int {
    auto it = s.find(key);
    if (it == s.end()) return 1;
    if (it->second.size() > len) return -1;
    len = it->second.size();
    if (len) std::memcpy(buf, it->second.data(), len);
    return 0;
  };
}

static auto writer(Store& s) {
  return [&s](const char* key, const uint8_t* buf, size_t len) {
    s[key] = std::vector<uint8_t>(buf, buf + len);
    return true;
  };
}

// Lays a config text out the way ESP-IDF's config_save does.
static Store stack_layout(const std::string& text) {
  Store s;
  const size_t total = text.size();
  if (total < chunk_max) {
    s["bt_cfg_key0"] = std::vector<uint8_t>(text.begin(), text.end());
    return s;
  }
  const size_t count = total / chunk_max;
  for (size_t i = 0; i <= count; ++i) {
    const size_t from = i * chunk_max;
    const size_t n = i == count ? total - from : chunk_max;
    s["bt_cfg_key" + std::to_string(i)] = std::vector<uint8_t>(text.begin() + from, text.begin() + from + n);
  }
  return s;
}

// Reads a store back the way ESP-IDF's config_parse does.
static std::string stack_read(const Store& s) {
  std::string out;
  for (size_t i = 0;; ++i) {
    auto it = s.find("bt_cfg_key" + std::to_string(i));
    if (it == s.end()) break;
    out.append(it->second.begin(), it->second.end());
    if (it->second.size() != chunk_max) break;
  }
  return out;
}

static std::string text_of(size_t n) {
  std::string t;
  for (size_t i = 0; t.size() < n; ++i) t += "[aa:bb:cc:dd:ee:" + std::to_string(i % 100) + "]\nLE_KEY_PENC = 0123456789abcdef\n";
  t.resize(n);
  return t;
}

int main() {
  static uint8_t buf[chunk_max];

  // Chunk keys match the stack's names.
  char key[key_cap];
  chunk_key(0, key);
  CHECK(std::strcmp(key, "bt_cfg_key0") == 0);
  chunk_key(12, key);
  CHECK(std::strcmp(key, "bt_cfg_key12") == 0);

  // A copy reads back identically through the stack's own reader: one short chunk,
  // several chunks, and an exact multiple of chunk_max (empty last chunk).
  for (size_t n : {size_t(1), size_t(400), chunk_max - 1, chunk_max, chunk_max + 1, 3 * chunk_max, 3 * chunk_max + 77}) {
    const Store src = stack_layout(text_of(n));
    Store dst;
    const Walked w = walk(reader(src), writer(dst), buf);
    CHECK(w.ok);
    CHECK(w.bytes == n);
    CHECK(stack_read(dst) == text_of(n));
  }

  // No store at all: nothing copied, still ok.
  {
    Store empty, dst;
    const Walked w = walk(reader(empty), writer(dst), buf);
    CHECK(w.ok);
    CHECK(w.chunks == 0);
    CHECK(dst.empty());
  }

  // Chunks past the first short one are not part of the store and are not copied.
  {
    Store src = stack_layout(text_of(300));
    src["bt_cfg_key1"] = {1, 2, 3};  // stale leftover from an older, longer config
    Store dst;
    const Walked w = walk(reader(src), writer(dst), buf);
    CHECK(w.chunks == 1);
    CHECK(dst.count("bt_cfg_key1") == 0);
  }

  // A read error or a failed write stops the walk and reports it.
  {
    Store src = stack_layout(text_of(10));
    src["bt_cfg_key0"] = std::vector<uint8_t>(chunk_max + 10, 'x');  // bigger than the buffer
    Store dst;
    CHECK(!walk(reader(src), writer(dst), buf).ok);
    const Store ok_src = stack_layout(text_of(10));
    auto refuse = [](const char*, const uint8_t*, size_t) { return false; };
    CHECK(!walk(reader(ok_src), refuse, buf).ok);
  }

  // The fingerprint follows the content: same bytes, same hash; one byte off, different.
  {
    auto none = [](const char*, const uint8_t*, size_t) { return true; };
    const Store a = stack_layout(text_of(2000));
    Store b = a;
    CHECK(walk(reader(a), none, buf).hash == walk(reader(b), none, buf).hash);
    b["bt_cfg_key1"][5] ^= 1;
    CHECK(walk(reader(a), none, buf).hash != walk(reader(b), none, buf).hash);
  }

  // Lost bonds: every kept address must still be in the live list.
  {
    const uint8_t phone[addr_len] = {0xF0, 0x01, 0x02, 0x03, 0x04, 0x05};
    const uint8_t mac[addr_len] = {0xC8, 0x11, 0x22, 0x33, 0x44, 0x55};
    uint8_t kept[2 * addr_len];
    std::memcpy(kept, phone, addr_len);
    std::memcpy(kept + addr_len, mac, addr_len);
    uint8_t live[2 * addr_len];
    std::memcpy(live, mac, addr_len);
    std::memcpy(live + addr_len, phone, addr_len);

    CHECK(!lost_any(kept, 2, live, 2));             // same bonds, any order
    CHECK(lost_any(kept, 2, live, 1));              // the phone's bond is gone
    CHECK(lost_any(kept, 1, live + addr_len, 0));   // every bond gone
    CHECK(!lost_any(kept, 1, live + addr_len, 1));  // phone still there
    CHECK(!lost_any(kept, 0, live, 2));             // nothing kept, nothing to lose
    CHECK(!lost_any(kept, 1, live, 2));             // a new bond on top is not a loss
  }

  if (failures == 0) std::printf("bond_store_test: all passed\n");
  return failures == 0 ? 0 : 1;
}
