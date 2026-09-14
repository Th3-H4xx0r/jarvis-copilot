// Everything the ball remembers: pairing + UI settings in NVS, saved home pages on the
// `pages` SPIFFS partition. Brightness and volume live with the board's own drivers.
#pragma once

#include <cstdint>
#include <string>
#include <utility>
#include <vector>

namespace jarvis::store {

struct Pairing {
    std::string server;     // "https://host"
    std::string cookie;     // "hermes_session=…"
    std::string cf_id;
    std::string cf_secret;
    bool paired() const { return !server.empty() && !cookie.empty(); }
};

Pairing LoadPairing();
void SavePairing(const Pairing& p);

struct Theme {
    // Placeholders until the app pushes JcAccent/JcTheme at setup.
    uint32_t accent = 0xFFFFFF;
    uint32_t success = 0xFFFFFF;
    uint32_t warning = 0xFFFFFF;
    uint32_t danger = 0xFFFFFF;
};

struct UiSettings {
    std::string home = "orb";
    bool wake_word = true;
    Theme theme;
    std::string timezone;  // IANA, for the app
    std::string tz_posix;  // for the clock
    bool clock_24h = false;
};

UiSettings LoadUi();
void SaveUi(const UiSettings& ui);

// Wipes pairing, UI settings, saved Wi-Fi and saved pages (BOOT held 5 s).
void FactoryReset();

bool MountPages();
std::vector<std::pair<std::string, std::string>> ListHomes();  // (id, title)
bool SaveHome(const std::string& id, const std::string& json);
std::string LoadHome(const std::string& id);  // "" when missing
bool DeleteHome(const std::string& id);

}  // namespace jarvis::store
