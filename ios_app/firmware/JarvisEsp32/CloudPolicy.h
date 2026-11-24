#pragma once
// When a board is on its direct Jarvis link (the Wi-Fi bridge): pure, host-tested in
// tests/cloud_policy_test.cpp. Live 2026-11-23: a 6-minute server freeze made both boards give up after
// 5 minutes and drop into Bluetooth mode, and the iPhone's passive Bluetooth link kept them there, so the PC
// power button stayed offline. Boards now never give up on the server.
#include <cstdint>

namespace cloudpolicy {

// On the direct link and offline this long: restart the board (still on the direct link) and try again.
constexpr uint32_t restart_after_ms = 10UL * 60UL * 1000UL;
// A board that must stay online (PC power button, door hub) leaves Bluetooth mode once the phone has
// sent nothing for this long, even while iOS keeps its Bluetooth link open.
constexpr uint32_t phone_quiet_ms = 5UL * 60UL * 1000UL;

// In Bluetooth mode: switch to the direct link now?
//   up_ms     how long Wi-Fi has been up (for other boards: up with no phone connected)
//   quiet_ms  since the phone's last request
inline bool auto_cloud_due(bool must_stay_online, bool phone_connected, uint32_t up_ms, uint32_t quiet_ms,
                           uint32_t delay_ms) {
  if (up_ms < delay_ms) return false;
  if (!phone_connected) return true;
  return must_stay_online && quiet_ms >= phone_quiet_ms;
}

// On the direct link: restart to try again from scratch? Never "give up and leave the link".
inline bool restart_due(uint32_t offline_ms) { return offline_ms >= restart_after_ms; }

}  // namespace cloudpolicy
