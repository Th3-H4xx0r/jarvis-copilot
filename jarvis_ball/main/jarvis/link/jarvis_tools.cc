// The ball_* bridge skills. The app's ball page and the agent both use these — one path.
#include <cJSON.h>
#include <esp_app_desc.h>
#include <esp_heap_caps.h>
#include <esp_mac.h>
#include <esp_system.h>
#include <esp_timer.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>
#include <wifi_manager.h>

#include "application.h"
#include "audio_codec.h"
#include "board.h"
#include "jarvis/board_caps.h"
#include "jarvis/link/jarvis_link.h"
#include "jarvis/logic/jarvis_logic.h"
#include "jarvis/store/jarvis_store.h"
#include "jarvis/ui/jarvis_ui.h"

namespace jarvis {

static const char* LinkName(LinkState s) {
    switch (s) {
        case LinkState::Connected: return "connected";
        case LinkState::Connecting: return "connecting";
        case LinkState::Unpaired: return "unpaired";
        default: return "offline";
    }
}

static std::string HexColor(uint32_t v) {
    char buf[8];
    snprintf(buf, sizeof(buf), "#%06X", static_cast<unsigned>(v & 0xFFFFFF));
    return buf;
}

static std::string PageTitle(const std::string& id) {
    if (id == "orb") return "Orb";
    if (id == "clock") return "Clock";
    for (auto& [hid, title] : store::ListHomes()) {
        if (hid == id) return title;
    }
    return id;
}

static void AddSettings(cJSON* out) {
    auto ui = store::LoadUi();
    auto& board = Board::GetInstance();
    cJSON_AddStringToObject(out, "home", ui.home.c_str());
    auto* backlight = board.GetBacklight();
    cJSON_AddNumberToObject(out, "brightness", backlight ? backlight->brightness() : 0);
    auto* codec = board.GetAudioCodec();
    cJSON_AddNumberToObject(out, "volume", codec ? codec->output_volume() : 0);
    cJSON_AddBoolToObject(out, "wake_word", ui.wake_word);
    cJSON* theme = cJSON_AddObjectToObject(out, "theme");
    cJSON_AddStringToObject(theme, "accent", HexColor(ui.theme.accent).c_str());
    cJSON_AddStringToObject(theme, "success", HexColor(ui.theme.success).c_str());
    cJSON_AddStringToObject(theme, "warning", HexColor(ui.theme.warning).c_str());
    cJSON_AddStringToObject(theme, "danger", HexColor(ui.theme.danger).c_str());
    cJSON_AddStringToObject(out, "timezone", ui.timezone.c_str());
    cJSON_AddStringToObject(out, "tz_posix", ui.tz_posix.c_str());
    cJSON_AddBoolToObject(out, "clock_24h", ui.clock_24h);
}

static std::string PrintJson(const cJSON* v) {
    char* s = cJSON_PrintUnformatted(v);
    std::string out = s ? s : "";
    cJSON_free(s);
    return out;
}

// Validation errors → one message the agent can act on.
static std::string CheckPage(const cJSON* page) {
    if (!cJSON_IsObject(page)) return "page: must be an object";
    if (PrintJson(page).size() > logic::kMaxPageBytes) return "page: too large (max 16 KB)";
    auto errors = logic::ValidatePage(page);
    if (errors.empty()) return "";
    std::string msg = "page is invalid:";
    for (auto& e : errors) msg += "\n- " + e;
    return msg;
}

static void RebootSoon() {
    xTaskCreate([](void*) {
        vTaskDelay(pdMS_TO_TICKS(800));
        esp_restart();
    }, "reboot", 2048, nullptr, 1, nullptr);
}

void RegisterBallTools() {
    auto& t = Tools();

    t.Add("ball_status",
          "Jarvis Ball status: battery, Wi-Fi, bridge link, current home and shown page, touch, wake word, firmware.",
          R"({"type":"object","properties":{}})", [](const cJSON*, cJSON* out) -> std::string {
              auto& board = Board::GetInstance();
              int level = 0;
              bool charging = false, discharging = false;
              cJSON* battery = cJSON_AddObjectToObject(out, "battery");
              if (board.GetBatteryLevel(level, charging, discharging)) {
                  cJSON_AddNumberToObject(battery, "level", level);
                  cJSON_AddBoolToObject(battery, "charging", charging);
              }
              auto& wifi = WifiManager::GetInstance();
              cJSON* w = cJSON_AddObjectToObject(out, "wifi");
              cJSON_AddStringToObject(w, "ssid", wifi.GetSsid().c_str());
              cJSON_AddNumberToObject(w, "rssi", wifi.GetRssi());
              cJSON_AddStringToObject(w, "ip", wifi.GetIpAddress().c_str());
              cJSON_AddStringToObject(out, "link", LinkName(Link::Get().state()));
              auto ui = store::LoadUi();
              cJSON* page = cJSON_AddObjectToObject(out, "page");
              cJSON_AddStringToObject(page, "home", ui.home.c_str());
              cJSON_AddStringToObject(page, "home_title", PageTitle(ui.home).c_str());
              cJSON_AddStringToObject(page, "shown", Ui::Get().ShownId().c_str());
              cJSON_AddBoolToObject(out, "touch", Caps().touch_present);
              cJSON_AddBoolToObject(out, "wake_word", ui.wake_word);
              cJSON_AddStringToObject(out, "fw", esp_app_get_description()->version);
              return std::string();
          });

    t.Add("ball_system_info", "Jarvis Ball firmware, ESP-IDF version, free memory, uptime, MAC and IP.",
          R"({"type":"object","properties":{}})", [](const cJSON*, cJSON* out) -> std::string {
              cJSON_AddStringToObject(out, "fw", esp_app_get_description()->version);
              cJSON_AddStringToObject(out, "idf", esp_get_idf_version());
              cJSON_AddNumberToObject(out, "heap_free", heap_caps_get_free_size(MALLOC_CAP_INTERNAL));
              cJSON_AddNumberToObject(out, "psram_free", heap_caps_get_free_size(MALLOC_CAP_SPIRAM));
              cJSON_AddNumberToObject(out, "uptime_s", static_cast<double>(esp_timer_get_time() / 1000000));
              uint8_t mac[6] = {0};
              esp_read_mac(mac, ESP_MAC_WIFI_STA);
              cJSON_AddStringToObject(out, "mac", logic::Mac12(mac).c_str());
              cJSON_AddStringToObject(out, "ip", WifiManager::GetInstance().GetIpAddress().c_str());
              return std::string();
          });

    t.Add("ball_reboot", "Restart the Jarvis Ball (it comes back online in about 15 seconds).",
          R"({"type":"object","properties":{}})", [](const cJSON*, cJSON* out) -> std::string {
              cJSON_AddBoolToObject(out, "ok", true);
              RebootSoon();
              return std::string();
          });

    t.Add("ball_settings_get", "Jarvis Ball settings: home page id, brightness, volume, wake word, theme, timezone, 24-hour clock.",
          R"({"type":"object","properties":{}})", [](const cJSON*, cJSON* out) -> std::string {
              AddSettings(out);
              return std::string();
          });

    t.Add("ball_settings_set",
          "Change Jarvis Ball settings. Pass only what changes. home: orb, clock or a saved home id. "
          "brightness/volume: 0-100. theme colours are #RRGGBB.",
          R"({"type":"object","properties":{"home":{"type":"string"},"brightness":{"type":"integer"},"volume":{"type":"integer"},"wake_word":{"type":"boolean"},"theme":{"type":"object"},"timezone":{"type":"string"},"tz_posix":{"type":"string"},"clock_24h":{"type":"boolean"}}})",
          [](const cJSON* args, cJSON* out) -> std::string {
              auto ui = store::LoadUi();
              auto& board = Board::GetInstance();
              const cJSON* v;
              if ((v = cJSON_GetObjectItemCaseSensitive(args, "home"))) {
                  std::string id = v->valuestring;
                  if (!logic::IsBuiltinHome(id) && store::LoadHome(id).empty()) return "home: no saved home named " + id;
                  ui.home = id;
              }
              if ((v = cJSON_GetObjectItemCaseSensitive(args, "brightness"))) {
                  int b = std::max(0, std::min(100, v->valueint));
                  if (auto* bl = board.GetBacklight()) bl->SetBrightness(static_cast<uint8_t>(b), true);
              }
              if ((v = cJSON_GetObjectItemCaseSensitive(args, "volume"))) {
                  if (auto* codec = board.GetAudioCodec()) codec->SetOutputVolume(std::max(0, std::min(100, v->valueint)));
              }
              if ((v = cJSON_GetObjectItemCaseSensitive(args, "wake_word"))) ui.wake_word = cJSON_IsTrue(v);
              if ((v = cJSON_GetObjectItemCaseSensitive(args, "theme"))) {
                  auto color = [&](const char* key, uint32_t& dst) -> std::string {
                      const cJSON* c = cJSON_GetObjectItemCaseSensitive(v, key);
                      if (!c) return "";
                      uint32_t rgb;
                      if (!cJSON_IsString(c) || !logic::ParseHexColor(c->valuestring, rgb)) return std::string("theme.") + key + ": must be #RRGGBB";
                      dst = rgb;
                      return "";
                  };
                  for (auto [key, dst] : {std::pair<const char*, uint32_t*>{"accent", &ui.theme.accent},
                                          {"success", &ui.theme.success}, {"warning", &ui.theme.warning},
                                          {"danger", &ui.theme.danger}}) {
                      std::string err = color(key, *dst);
                      if (!err.empty()) return err;
                  }
              }
              if ((v = cJSON_GetObjectItemCaseSensitive(args, "timezone"))) ui.timezone = v->valuestring;
              if ((v = cJSON_GetObjectItemCaseSensitive(args, "tz_posix"))) ui.tz_posix = v->valuestring;
              if ((v = cJSON_GetObjectItemCaseSensitive(args, "clock_24h"))) ui.clock_24h = cJSON_IsTrue(v);
              store::SaveUi(ui);
              Application::GetInstance().OnSettingsChanged();
              AddSettings(out);
              return std::string();
          });

    t.Add("ball_show",
          "Show a page on the Jarvis Ball's round 240 px screen right now (anything the user asks to see: "
          "a chart, weather, a list). Temporary: pressing Back discards it. Read the jarvis-ball skill for the page format.",
          R"({"type":"object","required":["page"],"properties":{"page":{"type":"object"}}})",
          [](const cJSON* args, cJSON* out) -> std::string {
              const cJSON* page = cJSON_GetObjectItemCaseSensitive(args, "page");
              std::string err = CheckPage(page);
              if (!err.empty()) return err;
              Ui::Get().CacheImages(FetchPageImages(page));
              Ui::Get().ShowPage(PrintJson(page));
              Application::GetInstance().Schedule([]() { Application::GetInstance().WakeScreen(); });
              cJSON_AddBoolToObject(out, "ok", true);
              return std::string();
          });

    t.Add("ball_home_save",
          "Save a page as a Jarvis Ball home screen (kept across reboots) and, by default, switch to it. "
          "Reusing an id replaces that home. Read the jarvis-ball skill for the page format.",
          R"({"type":"object","required":["page"],"properties":{"page":{"type":"object"},"make_home":{"type":"boolean"}}})",
          [](const cJSON* args, cJSON* out) -> std::string {
              const cJSON* page = cJSON_GetObjectItemCaseSensitive(args, "page");
              std::string err = CheckPage(page);
              if (!err.empty()) return err;
              const cJSON* id_item = cJSON_GetObjectItemCaseSensitive(page, "id");
              std::string id = cJSON_IsString(id_item) ? id_item->valuestring : "";
              if (id.empty()) {
                  char buf[16];
                  snprintf(buf, sizeof(buf), "home_%04x", static_cast<unsigned>(esp_random() & 0xFFFF));
                  id = buf;
              }
              if (logic::IsBuiltinHome(id)) return "id: orb and clock are built in; pick another id";
              auto homes = store::ListHomes();
              bool exists = std::any_of(homes.begin(), homes.end(), [&](auto& h) { return h.first == id; });
              if (!exists && static_cast<int>(homes.size()) >= logic::kMaxHomes) return "too many saved homes (16); delete one first";
              cJSON* copy = cJSON_Duplicate(page, true);
              cJSON_DeleteItemFromObjectCaseSensitive(copy, "id");
              cJSON_AddStringToObject(copy, "id", id.c_str());
              bool saved = store::SaveHome(id, PrintJson(copy));
              cJSON_Delete(copy);
              if (!saved) return "could not write the page to flash";
              const cJSON* make_home = cJSON_GetObjectItemCaseSensitive(args, "make_home");
              if (!make_home || cJSON_IsTrue(make_home)) {
                  auto ui = store::LoadUi();
                  ui.home = id;
                  store::SaveUi(ui);
              }
              Ui::Get().CacheImages(FetchPageImages(page));
              Application::GetInstance().OnSettingsChanged();
              cJSON_AddBoolToObject(out, "ok", true);
              cJSON_AddStringToObject(out, "id", id.c_str());
              return std::string();
          });

    t.Add("ball_home_list", "Jarvis Ball home screens: the built-in orb and clock plus saved custom homes, and which is current.",
          R"({"type":"object","properties":{}})", [](const cJSON*, cJSON* out) -> std::string {
              cJSON_AddStringToObject(out, "home", store::LoadUi().home.c_str());
              cJSON* pages = cJSON_AddArrayToObject(out, "pages");
              auto add = [&](const std::string& id, const std::string& title, bool builtin) {
                  cJSON* p = cJSON_CreateObject();
                  cJSON_AddStringToObject(p, "id", id.c_str());
                  cJSON_AddStringToObject(p, "title", title.c_str());
                  cJSON_AddBoolToObject(p, "builtin", builtin);
                  cJSON_AddItemToArray(pages, p);
              };
              add("orb", "Orb", true);
              add("clock", "Clock", true);
              for (auto& [id, title] : store::ListHomes()) add(id, title, false);
              return std::string();
          });

    t.Add("ball_home_get", "The JSON of a saved Jarvis Ball home page.",
          R"({"type":"object","required":["id"],"properties":{"id":{"type":"string"}}})",
          [](const cJSON* args, cJSON* out) -> std::string {
              std::string id = cJSON_GetObjectItemCaseSensitive(args, "id")->valuestring;
              cJSON* page = cJSON_Parse(store::LoadHome(id).c_str());
              if (!page) return "no saved home named " + id;
              cJSON_AddItemToObject(out, "page", page);
              return std::string();
          });

    t.Add("ball_home_delete", "Delete a saved Jarvis Ball home page. The built-in orb and clock can't be deleted.",
          R"({"type":"object","required":["id"],"properties":{"id":{"type":"string"}}})",
          [](const cJSON* args, cJSON* out) -> std::string {
              std::string id = cJSON_GetObjectItemCaseSensitive(args, "id")->valuestring;
              if (logic::IsBuiltinHome(id)) return "orb and clock are built in and can't be deleted";
              if (!store::DeleteHome(id)) return "no saved home named " + id;
              auto ui = store::LoadUi();
              if (ui.home == id) {
                  ui.home = "orb";
                  store::SaveUi(ui);
              }
              Application::GetInstance().OnSettingsChanged();
              cJSON_AddBoolToObject(out, "ok", true);
              return std::string();
          });

    t.Add("ball_data",
          "Update live values ({\"$\": key} bindings) on the current home page or the shown page without resending it. "
          "Values merge into the page's data; a saved home keeps them.",
          R"({"type":"object","required":["target","data"],"properties":{"target":{"type":"string"},"data":{"type":"object"}}})",
          [](const cJSON* args, cJSON* out) -> std::string {
              std::string target = cJSON_GetObjectItemCaseSensitive(args, "target")->valuestring;
              const cJSON* data = cJSON_GetObjectItemCaseSensitive(args, "data");
              if (target == "shown") {
                  if (!Ui::Get().MergeShownData(data)) return "no page is being shown";
              } else if (target == "home") {
                  auto ui = store::LoadUi();
                  if (logic::IsBuiltinHome(ui.home)) return "the current home (" + ui.home + ") has no data";
                  cJSON* page = cJSON_Parse(store::LoadHome(ui.home).c_str());
                  if (!page) return "the current home is missing";
                  cJSON* page_data = cJSON_GetObjectItemCaseSensitive(page, "data");
                  if (!cJSON_IsObject(page_data)) {
                      cJSON_DeleteItemFromObjectCaseSensitive(page, "data");
                      page_data = cJSON_AddObjectToObject(page, "data");
                  }
                  const cJSON* item;
                  cJSON_ArrayForEach(item, data) {
                      cJSON_DeleteItemFromObjectCaseSensitive(page_data, item->string);
                      cJSON_AddItemToObject(page_data, item->string, cJSON_Duplicate(item, true));
                  }
                  std::string json = PrintJson(page);
                  cJSON_Delete(page);
                  if (json.size() > logic::kMaxPageBytes) return "data makes the page too large (max 16 KB)";
                  store::SaveHome(ui.home, json);
                  Application::GetInstance().OnSettingsChanged();
              } else {
                  return "target: must be home or shown";
              }
              cJSON_AddBoolToObject(out, "ok", true);
              return std::string();
          });
}

// ---- images -----------------------------------------------------------------

static std::string HostOf(const std::string& url) {
    size_t start = url.find("://");
    if (start == std::string::npos) return "";
    start += 3;
    return url.substr(0, url.find('/', start));
}

static void CollectUrls(const cJSON* node, const cJSON* data, std::vector<std::string>& urls) {
    if (!cJSON_IsObject(node)) return;
    const cJSON* type = cJSON_GetObjectItemCaseSensitive(node, "type");
    if (cJSON_IsString(type) && !strcmp(type->valuestring, "image")) {
        const cJSON* src = cJSON_GetObjectItemCaseSensitive(node, "source");
        const cJSON* key = cJSON_GetObjectItemCaseSensitive(src, "$");
        if (cJSON_IsString(key)) src = cJSON_GetObjectItemCaseSensitive(data, key->valuestring);
        if (cJSON_IsString(src) && !strncmp(src->valuestring, "https://", 8)) urls.push_back(src->valuestring);
    }
    const cJSON* child;
    cJSON_ArrayForEach(child, cJSON_GetObjectItemCaseSensitive(node, "children")) CollectUrls(child, data, urls);
}

std::map<std::string, std::string> FetchPageImages(const cJSON* page) {
    std::map<std::string, std::string> out;
    std::vector<std::string> urls;
    CollectUrls(cJSON_GetObjectItemCaseSensitive(page, "root"), cJSON_GetObjectItemCaseSensitive(page, "data"), urls);
    store::Pairing pairing = store::LoadPairing();
    for (auto& url : urls) {
        if (out.count(url)) continue;
        bool own_server = !pairing.server.empty() && HostOf(url) == HostOf(pairing.server);
        HttpResult r = HttpRequest("GET", url, "", own_server ? pairing : store::Pairing{}, own_server, 10000, 100 * 1024);
        if (r.status == 200 && !r.body.empty() && r.body.size() <= 100 * 1024) out[url] = std::move(r.body);
    }
    return out;
}

}  // namespace jarvis
