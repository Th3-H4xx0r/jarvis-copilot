// The Bluetooth stack's bond store, as data. ESP-IDF's Bluedroid keeps every bond (and
// its own identity keys) as one text config in the NVS namespace "bt_config.conf", split
// into blobs "bt_cfg_key0", "bt_cfg_key1", … of chunk_max bytes; a reader keeps going
// while a chunk is exactly chunk_max long (osi/config.c, config_save / config_parse).
// BondKeeper copies that store byte for byte. The walking and the bond bookkeeping live
// here, free of NVS, so tests/bond_store_test.cpp can run them on the Mac.
#ifndef JARVIS_ESP32_BOND_STORE_H
#define JARVIS_ESP32_BOND_STORE_H

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

namespace jarvis::bonds {

constexpr const char* stack_namespace = "bt_config.conf";
constexpr size_t chunk_max = 1536;
constexpr size_t addr_len = 6;
constexpr size_t key_cap = 16;  // "bt_cfg_key" + up to 5 digits + NUL

inline void chunk_key(size_t i, char (&out)[key_cap]) {
  snprintf(out, key_cap, "bt_cfg_key%u", static_cast<unsigned>(i));
}

struct Walked {
  bool ok = true;
  size_t chunks = 0;
  size_t bytes = 0;
  uint32_t hash = 2166136261u;  // FNV-1a over the bytes, to skip rewriting an unchanged copy
};

/// Reads a chunked store the way the stack does and hands each chunk to `sink`.
/// read(key, buf, len) → 0 found (len set), 1 no such chunk, -1 error; len comes in as
/// the buffer size. sink(key, data, len) → false to stop. A missing store is ok, 0 chunks.
template <typename Read, typename Sink>
Walked walk(Read read, Sink sink, uint8_t* buf) {
  Walked w;
  for (size_t i = 0;; ++i) {
    char key[key_cap];
    chunk_key(i, key);
    size_t len = chunk_max;
    const int found = read(key, buf, len);
    if (found == 1) break;
    if (found != 0 || !sink(key, buf, len)) {
      w.ok = false;
      return w;
    }
    for (size_t j = 0; j < len; ++j) w.hash = (w.hash ^ buf[j]) * 16777619u;
    ++w.chunks;
    w.bytes += len;
    if (len != chunk_max) break;  // the stack stops at the first short chunk
  }
  return w;
}

/// True when a bond in `kept` is missing from `live` (both packed 6-byte addresses).
inline bool lost_any(const uint8_t* kept, size_t kept_n, const uint8_t* live, size_t live_n) {
  for (size_t i = 0; i < kept_n; ++i) {
    bool found = false;
    for (size_t j = 0; j < live_n && !found; ++j) {
      found = memcmp(kept + i * addr_len, live + j * addr_len, addr_len) == 0;
    }
    if (!found) return true;
  }
  return false;
}

/// What a check does: bring the copy up to date with the stack's store, reboot to put
/// the copy back, or stop healing.
enum class Step { refresh, heal, give_up };

/// Only a failed encryption can mean the stack erased a bond. After a successful pairing
/// the store holds the keys the phone uses right now, even when a kept address is gone:
/// Bluedroid files a bond under the address the phone paired from, and an iPhone pairs
/// from a rotating private address, so a phone forgotten in Settings and paired again
/// comes back under a new one. Healing then would write the old keys over the new pairing.
inline Step next_step(bool paired_last, bool lost, uint8_t heals, uint8_t max_heals) {
  if (paired_last || !lost) return Step::refresh;
  return heals >= max_heals ? Step::give_up : Step::heal;
}

}  // namespace jarvis::bonds

#endif  // JARVIS_ESP32_BOND_STORE_H
