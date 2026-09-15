// First-run pairing: a WPA2 hotspot with its passphrase in an on-screen QR code, and a
// small HTTP API the iOS app drives (docs/superpowers/specs/2026-09-14-jarvis-pod-design.md §2).
#pragma once

namespace jarvis {

class Setup {
public:
    static Setup& Get();
    void Start();  // never returns control of Wi-Fi: the pod reboots once paired
};

}  // namespace jarvis
