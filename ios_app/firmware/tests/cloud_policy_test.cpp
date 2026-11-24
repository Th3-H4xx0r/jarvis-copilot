// Host test for CloudPolicy.h: when a board goes (back) onto its direct Jarvis link, and that it never gives up.
// Live 2026-11-23: a 6-minute server freeze made both boards drop into Bluetooth mode for good.
#include "CloudPolicy.h"

#include <cstdio>
#include <cstdlib>

static int failures = 0;
#define CHECK(cond) do { if (!(cond)) { std::printf("FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond); ++failures; } } while (0)

int main() {
  using namespace cloudpolicy;
  const uint32_t min = 60UL * 1000UL;

  // Any linked board with no phone around goes back after the delay.
  CHECK(!auto_cloud_due(false, false, 59 * 1000, 0, min));
  CHECK(auto_cloud_due(false, false, min, 0, min));

  // An ordinary board stays on Bluetooth while the phone holds the link.
  CHECK(!auto_cloud_due(false, true, 24 * 60 * min, 24 * 60 * min, min));

  // A PC-button / door board goes back even with the phone's passive link, once the phone is quiet.
  CHECK(!auto_cloud_due(true, true, 10 * min, 4 * min, min));
  CHECK(auto_cloud_due(true, true, 10 * min, phone_quiet_ms, min));
  CHECK(!auto_cloud_due(true, true, 30 * 1000, phone_quiet_ms, min));   // Wi-Fi not up long enough yet

  // On the direct link: never give up, restart and try again after 10 minutes offline, forever.
  CHECK(!restart_due(9 * min));
  CHECK(restart_due(10 * min));
  CHECK(restart_due(24UL * 60UL * min));

  if (failures) { std::printf("%d failure(s)\n", failures); return EXIT_FAILURE; }
  std::printf("cloud policy: all passed\n");
  return EXIT_SUCCESS;
}
