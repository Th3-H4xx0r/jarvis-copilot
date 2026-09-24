#include "jarvis_store.h"

#include <cJSON.h>
#include <dirent.h>
#include <esp_log.h>
#include <esp_spiffs.h>
#include <ssid_manager.h>
#include <sys/stat.h>

#include <cstdio>
#include <mutex>

#include "settings.h"
#include "jarvis/logic/jarvis_logic.h"

#define TAG "JarvisStore"

namespace jarvis::store {

static const char* kNs = "jarvis";
static const char* kPagesDir = "/pages";
static std::mutex g_mutex;
static bool g_pages_mounted = false;

Pairing LoadPairing() {
    std::lock_guard<std::mutex> lock(g_mutex);
    Settings s(kNs);
    return Pairing{s.GetString("server"), s.GetString("cookie"), s.GetString("cf_id"), s.GetString("cf_secret")};
}

void SavePairing(const Pairing& p) {
    std::lock_guard<std::mutex> lock(g_mutex);
    Settings s(kNs, true);
    s.SetString("server", p.server);
    s.SetString("cookie", p.cookie);
    s.SetString("cf_id", p.cf_id);
    s.SetString("cf_secret", p.cf_secret);
}

UiSettings LoadUi() {
    std::lock_guard<std::mutex> lock(g_mutex);
    Settings s(kNs);
    UiSettings ui;
    ui.home = s.GetString("home", "orb");
    ui.wake_word = s.GetBool("wake_word", true);
    ui.theme.accent = static_cast<uint32_t>(s.GetInt("accent", static_cast<int32_t>(ui.theme.accent)));
    ui.theme.success = static_cast<uint32_t>(s.GetInt("success", static_cast<int32_t>(ui.theme.success)));
    ui.theme.warning = static_cast<uint32_t>(s.GetInt("warning", static_cast<int32_t>(ui.theme.warning)));
    ui.theme.danger = static_cast<uint32_t>(s.GetInt("danger", static_cast<int32_t>(ui.theme.danger)));
    ui.timezone = s.GetString("timezone");
    ui.tz_posix = s.GetString("tz_posix");
    ui.clock_24h = s.GetBool("clock_24h", false);
    ui.noise_cancel = s.GetBool("noise_cancel", true);
    ui.end_pause_ms = logic::ClampEndPauseMs(s.GetInt("end_pause_ms", logic::kEndPauseDefaultMs));
    return ui;
}

void SaveUi(const UiSettings& ui) {
    std::lock_guard<std::mutex> lock(g_mutex);
    Settings s(kNs, true);
    s.SetString("home", ui.home);
    s.SetBool("wake_word", ui.wake_word);
    s.SetBool("noise_cancel", ui.noise_cancel);
    s.SetInt("end_pause_ms", logic::ClampEndPauseMs(ui.end_pause_ms));
    s.SetInt("accent", static_cast<int32_t>(ui.theme.accent));
    s.SetInt("success", static_cast<int32_t>(ui.theme.success));
    s.SetInt("warning", static_cast<int32_t>(ui.theme.warning));
    s.SetInt("danger", static_cast<int32_t>(ui.theme.danger));
    s.SetString("timezone", ui.timezone);
    s.SetString("tz_posix", ui.tz_posix);
    s.SetBool("clock_24h", ui.clock_24h);
}

bool MountPages() {
    if (g_pages_mounted) return true;
    esp_vfs_spiffs_conf_t conf = {
        .base_path = kPagesDir,
        .partition_label = "pages",
        .max_files = 4,
        .format_if_mount_failed = true,
    };
    esp_err_t err = esp_vfs_spiffs_register(&conf);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "pages mount failed: %s", esp_err_to_name(err));
        return false;
    }
    g_pages_mounted = true;
    return true;
}

static std::string PathFor(const std::string& id) { return std::string(kPagesDir) + "/" + id + ".json"; }

std::vector<std::pair<std::string, std::string>> ListHomes() {
    std::vector<std::pair<std::string, std::string>> out;
    if (!MountPages()) return out;
    DIR* dir = opendir(kPagesDir);
    if (!dir) return out;
    while (dirent* e = readdir(dir)) {
        std::string name = e->d_name;
        if (name.size() <= 5 || name.compare(name.size() - 5, 5, ".json") != 0) continue;
        std::string id = name.substr(0, name.size() - 5);
        std::string title = id;
        cJSON* page = cJSON_Parse(LoadHome(id).c_str());
        const cJSON* t = cJSON_GetObjectItemCaseSensitive(page, "title");
        if (cJSON_IsString(t) && t->valuestring[0]) title = t->valuestring;
        cJSON_Delete(page);
        out.emplace_back(id, title);
    }
    closedir(dir);
    return out;
}

bool SaveHome(const std::string& id, const std::string& json) {
    if (!MountPages()) return false;
    std::lock_guard<std::mutex> lock(g_mutex);
    // SPIFFS names cap at 31 chars: a fixed short temp name keeps long ids writable.
    std::string tmp = std::string(kPagesDir) + "/.tmp";
    FILE* f = fopen(tmp.c_str(), "wb");
    if (!f) return false;
    bool ok = fwrite(json.data(), 1, json.size(), f) == json.size();
    ok = (fclose(f) == 0) && ok;
    if (!ok) {
        remove(tmp.c_str());
        return false;
    }
    remove(PathFor(id).c_str());
    return rename(tmp.c_str(), PathFor(id).c_str()) == 0;
}

std::string LoadHome(const std::string& id) {
    if (!MountPages()) return "";
    std::lock_guard<std::mutex> lock(g_mutex);
    FILE* f = fopen(PathFor(id).c_str(), "rb");
    if (!f) return "";
    std::string out;
    char buf[1024];
    size_t n;
    while ((n = fread(buf, 1, sizeof(buf), f)) > 0) out.append(buf, n);
    fclose(f);
    return out;
}

bool DeleteHome(const std::string& id) {
    if (!MountPages()) return false;
    std::lock_guard<std::mutex> lock(g_mutex);
    return remove(PathFor(id).c_str()) == 0;
}

void FactoryReset() {
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        Settings s(kNs, true);
        s.EraseAll();
    }
    SsidManager::GetInstance().Clear();
    for (auto& [id, title] : ListHomes()) DeleteHome(id);
    ESP_LOGW(TAG, "factory reset done");
}

}  // namespace jarvis::store
