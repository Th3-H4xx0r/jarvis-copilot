// Host tests for main/jarvis/logic — run with scripts/test_host.sh.
#include <cJSON.h>

#include <cstdio>
#include <cstring>
#include <string>

#include "jarvis_logic.h"

using namespace jarvis::logic;

static int failures = 0;
#define CHECK(cond)                                                     \
    do {                                                                \
        if (!(cond)) {                                                  \
            ++failures;                                                 \
            fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
        }                                                               \
    } while (0)

static std::vector<std::string> Validate(const char* json) {
    cJSON* page = cJSON_Parse(json);
    auto errors = ValidatePage(page);
    cJSON_Delete(page);
    return errors;
}

static bool Contains(const std::vector<std::string>& errs, const char* needle) {
    for (auto& e : errs) {
        if (e.find(needle) != std::string::npos) return true;
    }
    return false;
}

int main() {
    uint8_t rnd[12] = {0, 1, 2, 30, 31, 255, 7, 8, 9, 10, 11, 12};
    std::string pw = MakePassphrase(rnd, sizeof(rnd));
    CHECK(pw.size() == 12);
    CHECK(pw.find_first_not_of(kCodeAlphabet) == std::string::npos);

    uint8_t mac[6] = {0x24, 0x0a, 0xc4, 0x12, 0x64, 0xd5};
    CHECK(ApSsid(mac) == "Jarvis-64D5");
    CHECK(Mac12(mac) == "240ac41264d5");
    CHECK(SetupQrPayload("Jarvis-64D5", "ABC", "240ac41264d5") ==
          "jarviscopilot://device-setup?v=1&kind=jarvis_ball&ssid=Jarvis-64D5&pw=ABC&id=240ac41264d5");

    CHECK(SetupStatusJson("failed", "wifi_auth", "Wrong password") ==
          "{\"state\":\"failed\",\"error\":\"wifi_auth\",\"message\":\"Wrong password\"}");

    SetupRequest req;
    CHECK(ParseSetupRequest("{\"wifi\":{\"ssid\":\"Home\",\"password\":\"pw\"},\"server\":\"https://j.example.com\","
                            "\"code\":\"ABC-DEF\",\"cf_access\":{\"client_id\":\"id\",\"client_secret\":\"sec\"},"
                            "\"theme\":{\"accent\":\"#3EC7C7\"},\"timezone\":\"America/Los_Angeles\","
                            "\"tz_posix\":\"PST8PDT,M3.2.0,M11.1.0\",\"clock_24h\":true}",
                            req) == "");
    CHECK(req.ssid == "Home" && req.cf_secret == "sec" && req.accent == "#3EC7C7" && req.clock_24h);
    CHECK(req.tz_posix == "PST8PDT,M3.2.0,M11.1.0");
    SetupRequest bad;
    CHECK(ParseSetupRequest("{\"server\":\"https://x\",\"code\":\"A\"}", bad) == "wifi: required");
    CHECK(ParseSetupRequest("{\"wifi\":{\"ssid\":\"H\"},\"server\":\"ftp://x\",\"code\":\"A\"}", bad).find("server") == 0);
    CHECK(ParseSetupRequest("not json", bad) == "body: not a JSON object");

    CHECK(BackoffSeconds(0) == 1 && BackoffSeconds(3) == 8 && BackoffSeconds(5) == 32 && BackoffSeconds(9) == 60);
    CHECK(WsUrl("https://j.example.com/", "/api/devices/bridge/ws") == "wss://j.example.com/api/devices/bridge/ws");
    CHECK(WsUrl("http://10.0.0.2:8787", "/x") == "ws://10.0.0.2:8787/x");
    CHECK(JoinUrl("https://a.b/base/", "/api") == "https://a.b/base/api");

    uint32_t rgb = 0;
    CHECK(ParseHexColor("#3EC7C7", rgb) && rgb == 0x3EC7C7);
    CHECK(!ParseHexColor("3EC7C7", rgb) && !ParseHexColor("#3EC7CZ", rgb));

    cJSON* schema = cJSON_Parse("{\"type\":\"object\",\"required\":[\"id\"],\"properties\":{\"id\":{\"type\":\"string\"},\"n\":{\"type\":\"integer\"}}}");
    cJSON* ok_args = cJSON_Parse("{\"id\":\"x\",\"n\":3}");
    cJSON* missing = cJSON_Parse("{}");
    cJSON* wrong = cJSON_Parse("{\"id\":\"x\",\"n\":1.5}");
    CHECK(ValidateArgs(schema, ok_args) == "");
    CHECK(ValidateArgs(schema, missing) == "id: required");
    CHECK(ValidateArgs(schema, wrong) == "n: must be integer");
    cJSON_Delete(schema);
    cJSON_Delete(ok_args);
    cJSON_Delete(missing);
    cJSON_Delete(wrong);

    // Pages
    CHECK(Validate("{\"id\":\"nvda\",\"title\":\"NVIDIA\",\"root\":{\"type\":\"vstack\",\"children\":["
                   "{\"type\":\"text\",\"value\":{\"$\":\"price\"},\"style\":{\"size\":40,\"weight\":\"bold\"}},"
                   "{\"type\":\"chart\",\"kind\":\"line\",\"points\":[1,2,3],\"style\":{\"color\":\"accent\"}},"
                   "{\"type\":\"symbol\",\"name\":\"wifi\"},"
                   "{\"type\":\"gauge\",\"value\":40,\"min\":0,\"max\":100,\"onTap\":{\"action\":\"voice\",\"text\":\"hi\"}}]},"
                   "\"data\":{\"price\":\"$1\"}}")
              .empty());
    CHECK(Contains(Validate("{\"root\":{\"type\":\"symbol\",\"name\":\"wif\"}}"), "did you mean wifi"));
    CHECK(Contains(Validate("{\"root\":{\"type\":\"blink\"}}"), "unknown type"));
    CHECK(Contains(Validate("{}"), "root: required"));
    CHECK(Contains(Validate("{\"root\":{\"type\":\"text\"}}"), "root.value: required"));
    CHECK(Contains(Validate("{\"root\":{\"type\":\"vstack\",\"children\":[{\"type\":\"text\",\"value\":\"a\",\"style\":{\"color\":\"pink\"}}]}}"),
                   "root.children[0].style.color"));
    CHECK(Contains(Validate("{\"root\":{\"type\":\"image\",\"source\":\"http://x/a.png\"}}"), "https"));
    CHECK(Contains(Validate("{\"root\":{\"type\":\"text\",\"value\":\"a\",\"onTap\":{\"action\":\"page\"}}}"), "voice or home"));
    CHECK(Contains(Validate("{\"id\":\"Bad Id\",\"root\":{\"type\":\"spacer\"}}"), "id:"));

    std::string deep = "{\"root\":";
    for (int i = 0; i < 9; ++i) deep += "{\"type\":\"vstack\",\"children\":[";
    deep += "{\"type\":\"spacer\"}";
    for (int i = 0; i < 9; ++i) deep += "]}";
    deep += "}";
    CHECK(Contains(Validate(deep.c_str()), "too deep"));

    std::string wide = "{\"root\":{\"type\":\"vstack\",\"children\":[";
    for (int i = 0; i < 61; ++i) wide += std::string(i ? "," : "") + "{\"type\":\"dot\"}";
    wide += "]}}";
    CHECK(Contains(Validate(wide.c_str()), "too many nodes"));

    CHECK(IsBuiltinHome("orb") && IsBuiltinHome("clock") && !IsBuiltinHome("weather"));
    CHECK(ValidPageId("weather_1") && !ValidPageId("") && !ValidPageId("UPPER"));

    if (failures) {
        fprintf(stderr, "%d failure(s)\n", failures);
        return 1;
    }
    printf("host tests: all passed\n");
    return 0;
}
