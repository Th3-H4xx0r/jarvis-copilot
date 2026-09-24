// Pure logic with no ESP-IDF dependency (only cJSON), so host_tests can run it on a Mac.
#pragma once

#include <cstdint>
#include <string>
#include <vector>

struct cJSON;

namespace jarvis::logic {

// ---- setup ---------------------------------------------------------------
// The pairing-code alphabet: no 0/O, 1/I/L.
extern const char kCodeAlphabet[];

// 12 chars from `random_bytes` mapped onto kCodeAlphabet.
std::string MakePassphrase(const uint8_t* random_bytes, size_t n);

// jarviscopilot://device-setup?v=1&kind=jarvis_pod&ssid=..&pw=..&id=..
std::string SetupQrPayload(const std::string& ssid, const std::string& passphrase, const std::string& mac12);

// "Jarvis-64D5" from the last two MAC bytes.
std::string ApSsid(const uint8_t mac[6]);
std::string Mac12(const uint8_t mac[6]);

std::string SetupStatusJson(const std::string& state, const std::string& error, const std::string& message);

struct SetupRequest {
    std::string ssid, password, server, code, cf_id, cf_secret;
    std::string accent, success, warning, danger;  // "#RRGGBB"
    std::string timezone;   // IANA id, shown and compared by the app
    std::string tz_posix;   // what the pod's clock actually uses (computed by the app)
    bool clock_24h = false;
};
// Empty string on success, else "<field>: <reason>".
std::string ParseSetupRequest(const char* body, SetupRequest& out);

// ---- link ----------------------------------------------------------------
// Reconnect delay for the nth consecutive failure (0-based): 1,2,4..60 s, before jitter.
int BackoffSeconds(int attempt);

// "https://host[:port][/base]" + "/api/x" → "wss://host[:port][/base]/api/x".
std::string WsUrl(const std::string& server, const std::string& path);
std::string JoinUrl(const std::string& server, const std::string& path);

// Checks `args` against a JSON-schema object's `required` + property `type`s.
// Empty string when valid.
std::string ValidateArgs(const cJSON* schema, const cJSON* args);

// "#3EC7C7" → 0x3EC7C7; returns false when malformed.
bool ParseHexColor(const std::string& s, uint32_t& out);

// ---- pages ---------------------------------------------------------------
constexpr int kMaxNodes = 60;
constexpr int kMaxDepth = 8;
constexpr size_t kMaxPageBytes = 16 * 1024;
constexpr int kMaxHomes = 16;
constexpr int kMaxChartPoints = 200;

// Every problem found, each "json.path: message". Empty = valid.
std::vector<std::string> ValidatePage(const cJSON* page);

// The known name (from symbols.def) or nullptr when the renderer can't draw it.
const char* SymbolGlyph(const std::string& sf_name);
// Up to 3 known names close to `sf_name`, for error messages.
std::vector<std::string> NearSymbols(const std::string& sf_name);

bool IsBuiltinHome(const std::string& id);

// A transcript that only asks voice to stop listening: "Stop.", "Never mind, Jarvis",
// "okay that's all", "stop stop". Commands that happen to contain the words
// ("stop the music", "cancel my meeting") are not.
bool IsStopPhrase(const std::string& transcript);
bool ValidPageId(const std::string& id);

// How long a pause ends a turn — "Pause before Jarvis answers" on the phone's Pod page.
// 550 ms was the old fixed timing, and cut sentences in half at a breath.
constexpr int kEndPauseDefaultMs = 1000;
constexpr int kEndPauseMinMs = 400;
constexpr int kEndPauseMaxMs = 3000;
int ClampEndPauseMs(int ms);

// The three ways a turn ends, all following the one setting: the VAD has heard silence
// this long; the level is back at the floor this long while the VAD agrees; or the
// level alone says quiet this long (room noise can hold the VAD at "speech").
struct EndTimings {
    int64_t vad_silence_ms;
    int64_t energy_ms;
    int64_t energy_only_ms;
};
EndTimings EndTimingsFor(int end_pause_ms);

}  // namespace jarvis::logic
