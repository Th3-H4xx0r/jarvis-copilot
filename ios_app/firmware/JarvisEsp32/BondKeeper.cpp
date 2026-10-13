#include "BondKeeper.h"

#include <esp_gap_ble_api.h>
#include <nvs.h>

#include "BondStore.h"

namespace jarvis {
namespace {

constexpr const char* copy_namespace = "jc_bt_copy";  // same layout as the stack's store
constexpr const char* meta_namespace = "jc_bonds";
constexpr const char* key_ids = "ids";      // packed addresses of the bonds in the copy
constexpr const char* key_hash = "hash";    // Walked::hash of the copy
constexpr const char* key_heals = "heals";  // heals since the last successful encryption
constexpr const char* key_heal = "heal";    // set: the next boot puts the copy back
constexpr uint8_t max_heals = 3;
constexpr int max_bonds = 15;               // CONFIG_BT_SMP_MAX_BONDS
using Addrs = uint8_t[max_bonds * bonds::addr_len];

// An NVS handle that closes itself.
class Nvs {
 public:
  Nvs(const char* ns, nvs_open_mode_t mode) { ok_ = nvs_open(ns, mode, &h_) == ESP_OK; }
  ~Nvs() { if (ok_) nvs_close(h_); }
  Nvs(const Nvs&) = delete;
  Nvs& operator=(const Nvs&) = delete;
  explicit operator bool() const { return ok_; }
  nvs_handle_t operator*() const { return h_; }

 private:
  nvs_handle_t h_ = 0;
  bool ok_ = false;
};

auto reader(const Nvs& nvs) {
  return [&nvs](const char* key, uint8_t* buf, size_t& len) -> int {
    const esp_err_t err = nvs_get_blob(*nvs, key, buf, &len);
    return err == ESP_OK ? 0 : err == ESP_ERR_NVS_NOT_FOUND ? 1 : -1;
  };
}

auto writer(const Nvs& nvs) {
  return [&nvs](const char* key, const uint8_t* buf, size_t len) {
    return nvs_set_blob(*nvs, key, buf, len) == ESP_OK;
  };
}

bool skip(const char*, const uint8_t*, size_t) { return true; }

// The bonds the stack holds right now, as packed addresses. -1 when it can't say.
int live_bonds(Addrs& out) {
  int n = esp_ble_get_bond_device_num();
  if (n < 0) return -1;
  if (n == 0) return 0;
  if (n > max_bonds) n = max_bonds;
  auto* list = static_cast<esp_ble_bond_dev_t*>(malloc(sizeof(esp_ble_bond_dev_t) * n));
  if (list == nullptr) return -1;
  if (esp_ble_get_bond_device_list(&n, list) != ESP_OK) n = -1;
  for (int i = 0; i < n; ++i) memcpy(out + i * bonds::addr_len, list[i].bd_addr, bonds::addr_len);
  free(list);
  return n;
}

}  // namespace

void BondKeeper::restore_if_pending() {
  {
    Nvs meta(meta_namespace, NVS_READWRITE);
    uint8_t heal = 0;
    if (!meta || nvs_get_u8(*meta, key_heal, &heal) != ESP_OK || heal == 0) return;
    nvs_erase_key(*meta, key_heal);  // one attempt per request, so never a boot loop
    nvs_commit(*meta);
  }
  auto* buf = static_cast<uint8_t*>(malloc(bonds::chunk_max));
  if (buf == nullptr) return;
  Nvs copy(copy_namespace, NVS_READONLY);
  Nvs stack(bonds::stack_namespace, NVS_READWRITE);
  const bonds::Walked saved = copy ? bonds::walk(reader(copy), skip, buf) : bonds::Walked{false};
  if (stack && saved.ok && saved.chunks > 0) {
    nvs_erase_all(*stack);  // drop chunks of the erased-bond config the copy won't overwrite
    const bonds::Walked w = bonds::walk(reader(copy), writer(stack), buf);
    const bool ok = w.ok && nvs_commit(*stack) == ESP_OK;
    Serial.printf("[bond] %s the saved Bluetooth bonds (%u bytes)\n", ok ? "put back" : "failed to put back",
                  static_cast<unsigned>(w.bytes));
  } else {
    Serial.println("[bond] no saved copy to put back");
  }
  free(buf);
}

bool BondKeeper::service(uint32_t now) {
  const uint32_t at = check_at_ms_;
  if (at == 0 || static_cast<int32_t>(now - at) < 0) return false;
  check_at_ms_ = 0;
  const bool succeeded = succeeded_;
  succeeded_ = false;

  Addrs live;
  const int live_n = live_bonds(live);
  if (live_n < 0) return false;
  Nvs meta(meta_namespace, NVS_READWRITE);
  if (!meta) return false;

  Addrs kept;
  size_t kept_len = sizeof(kept);
  if (nvs_get_blob(*meta, key_ids, kept, &kept_len) != ESP_OK) kept_len = 0;
  uint8_t heals = 0;
  nvs_get_u8(*meta, key_heals, &heals);
  if (succeeded && heals != 0) {  // the put-back bond worked: re-arm
    heals = 0;
    nvs_set_u8(*meta, key_heals, 0);
    nvs_commit(*meta);
  }

  if (bonds::lost_any(kept, kept_len / bonds::addr_len, live, live_n)) {
    if (heals >= max_heals) {
      Serial.println("[bond] a saved bond is gone again; waiting for the phone instead of rebooting");
      return false;
    }
    nvs_set_u8(*meta, key_heals, heals + 1);
    nvs_set_u8(*meta, key_heal, 1);
    nvs_commit(*meta);
    Serial.printf("[bond] the Bluetooth stack erased a saved bond (%d of %u left); rebooting to put it back\n",
                  live_n, static_cast<unsigned>(kept_len / bonds::addr_len));
    return true;
  }

  // Nothing lost: bring the copy up to date (a new bond, or new keys after a re-pair).
  if (live_n == 0) return false;
  auto* buf = static_cast<uint8_t*>(malloc(bonds::chunk_max));
  if (buf == nullptr) return false;
  Nvs stack(bonds::stack_namespace, NVS_READONLY);
  const bonds::Walked current = stack ? bonds::walk(reader(stack), skip, buf) : bonds::Walked{false};
  uint32_t saved_hash = 0;
  const bool unchanged = nvs_get_u32(*meta, key_hash, &saved_hash) == ESP_OK && saved_hash == current.hash;
  if (current.ok && current.chunks > 0 && !unchanged) {
    // Forget the old copy's bonds first: a copy cut short by a power cut is never put back.
    nvs_erase_key(*meta, key_ids);
    nvs_erase_key(*meta, key_hash);
    nvs_commit(*meta);
    Nvs copy(copy_namespace, NVS_READWRITE);
    if (copy && nvs_erase_all(*copy) == ESP_OK) {
      const bonds::Walked w = bonds::walk(reader(stack), writer(copy), buf);
      if (w.ok && nvs_commit(*copy) == ESP_OK) {
        nvs_set_blob(*meta, key_ids, live, live_n * bonds::addr_len);
        nvs_set_u32(*meta, key_hash, w.hash);
        nvs_commit(*meta);
        Serial.printf("[bond] saved a copy of %d Bluetooth bond(s) (%u bytes)\n", live_n,
                      static_cast<unsigned>(w.bytes));
      }
    }
  }
  free(buf);
  return false;
}

}  // namespace jarvis
