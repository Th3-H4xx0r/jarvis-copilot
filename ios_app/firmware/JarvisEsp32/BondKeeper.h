// Keeps the phone's Bluetooth bond from being erased by the Bluetooth stack.
//
// ESP-IDF's Bluedroid deletes a peer's bond, in RAM and in flash, whenever a pairing or
// encryption with it fails, for any reason (bta_dm_act.c on BTM_LE_COMPLT_EVT, btc_dm.c on
// auth complete). Encryption started by an iPhone goes through that same path
// (smp_act.c, smp_link_encrypted), so one re-encryption that fails — the phone walking out
// of range mid-handshake is enough — erases the bond while the iPhone keeps its half. From
// then on iOS refuses every connection ("peer removed pairing information") until the user
// forgets the board in Settings. The stack has no switch to stop it.
//
// So the board keeps its own copy of the stack's bond store (BondStore.h), refreshed after
// each pairing or encryption. When a bond that copy holds disappears after a failed one
// (after a successful pairing the store is the truth: bonds::next_step), the board asks
// for a heal and reboots; at the next boot, before Bluetooth starts (the stack reads its store
// only then), the copy goes back and the iPhone's key works again. A successful encryption
// re-arms it; after max_heals in a row without one it stops, so a phone whose keys really
// are different can't keep the board rebooting.
//
// Threading: on_auth() runs on the Bluetooth task and only records what happened; the
// NVS work is in service() (loop) and restore_if_pending() (setup).
#ifndef JARVIS_ESP32_BOND_KEEPER_H
#define JARVIS_ESP32_BOND_KEEPER_H

#include <Arduino.h>

namespace jarvis {

class BondKeeper {
 public:
  /// setup(), before BLEDevice::init: puts the saved copy back if the last boot asked.
  void restore_if_pending();
  /// setup(), once Bluetooth is up: a board bonded before this firmware gets its first
  /// copy without waiting for the phone.
  void begin() { check_in(2000); }
  /// Bluetooth task: a pairing or re-encryption finished.
  void on_auth(bool success) {
    if (success) succeeded_ = true;
    paired_last_ = success;
    check_in(success ? 3000 : 500);  // let the stack finish rewriting its store first
  }
  /// loop(): refreshes the copy, or finds an erased bond. True when the board must
  /// reboot to put it back.
  bool service(uint32_t now);

 private:
  void check_in(uint32_t ms) { check_at_ms_ = (millis() + ms) | 1u; }

  volatile uint32_t check_at_ms_ = 0;  // 0 = nothing pending
  volatile bool succeeded_ = false;    // an encryption succeeded since the last check
  volatile bool paired_last_ = false;  // the latest pairing/encryption succeeded (boot: no)
};

}  // namespace jarvis

#endif  // JARVIS_ESP32_BOND_KEEPER_H
