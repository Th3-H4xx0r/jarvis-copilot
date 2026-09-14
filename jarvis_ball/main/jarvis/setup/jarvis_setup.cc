#include "jarvis_setup.h"

#include <cJSON.h>
#include <esp_event.h>
#include <esp_http_server.h>
#include <esp_log.h>
#include <esp_mac.h>
#include <esp_netif.h>
#include <esp_random.h>
#include <esp_system.h>
#include <esp_wifi.h>
#include <freertos/FreeRTOS.h>
#include <freertos/event_groups.h>
#include <freertos/task.h>
#include <ssid_manager.h>

#include <algorithm>
#include <atomic>
#include <cstring>
#include <mutex>
#include <string>

#include "board.h"
#include "jarvis/board_caps.h"
#include "jarvis/link/jarvis_link.h"
#include "jarvis/logic/jarvis_logic.h"
#include "jarvis/store/jarvis_store.h"
#include "jarvis/ui/jarvis_ui.h"

#define TAG "JarvisSetup"

namespace jarvis {

namespace {

constexpr EventBits_t kGotIp = BIT0;
constexpr EventBits_t kDisconnected = BIT1;

std::mutex g_status_mutex;
std::string g_state = "idle", g_error, g_message;
std::atomic<bool> g_busy{false};
std::atomic<uint8_t> g_disconnect_reason{0};
EventGroupHandle_t g_events = nullptr;
logic::SetupRequest g_request;
std::string g_mac12;
esp_netif_t* g_sta = nullptr;

void SetStatus(const std::string& state, const std::string& error = "", const std::string& message = "") {
    {
        std::lock_guard<std::mutex> lock(g_status_mutex);
        g_state = state;
        g_error = error;
        g_message = message;
    }
    Ui::Get().SetSetupMessage(message);
}

void OnWifiEvent(void*, esp_event_base_t base, int32_t id, void* data) {
    if (base == WIFI_EVENT && id == WIFI_EVENT_STA_DISCONNECTED) {
        g_disconnect_reason = static_cast<wifi_event_sta_disconnected_t*>(data)->reason;
        xEventGroupSetBits(g_events, kDisconnected);
    } else if (base == IP_EVENT && id == IP_EVENT_STA_GOT_IP) {
        xEventGroupSetBits(g_events, kGotIp);
    }
}

// "" for a transient reason worth another try.
std::string WifiError(uint8_t reason) {
    switch (reason) {
        case WIFI_REASON_MIC_FAILURE:
        case WIFI_REASON_4WAY_HANDSHAKE_TIMEOUT:
        case WIFI_REASON_AUTH_FAIL:
        case WIFI_REASON_HANDSHAKE_TIMEOUT:
            return "wifi_auth";
        case WIFI_REASON_NO_AP_FOUND:
        case WIFI_REASON_NO_AP_FOUND_W_COMPATIBLE_SECURITY:
        case WIFI_REASON_NO_AP_FOUND_IN_AUTHMODE_THRESHOLD:
        case WIFI_REASON_NO_AP_FOUND_IN_RSSI_THRESHOLD:
            return "wifi_not_found";
        default:
            return "";
    }
}

void Attempt() {
    const logic::SetupRequest req = g_request;
    SetStatus("joining_wifi", "", "Joining " + req.ssid + "…");

    wifi_config_t sta = {};
    strncpy(reinterpret_cast<char*>(sta.sta.ssid), req.ssid.c_str(), sizeof(sta.sta.ssid));
    strncpy(reinterpret_cast<char*>(sta.sta.password), req.password.c_str(), sizeof(sta.sta.password));
    sta.sta.threshold.authmode = req.password.empty() ? WIFI_AUTH_OPEN : WIFI_AUTH_WEP;
    esp_wifi_disconnect();
    vTaskDelay(pdMS_TO_TICKS(200));  // let that disconnect's own event land before we listen
    esp_wifi_set_config(WIFI_IF_STA, &sta);
    // Up to three tries inside 20 s: transient failures (AP busy, assoc leave) are common.
    const TickType_t deadline = xTaskGetTickCount() + pdMS_TO_TICKS(20000);
    EventBits_t bits = 0;
    std::string err = "no_ip";
    for (int attempt = 0; attempt < 3; ++attempt) {
        xEventGroupClearBits(g_events, kGotIp | kDisconnected);
        esp_wifi_connect();
        TickType_t now = xTaskGetTickCount();
        if (now >= deadline) break;
        bits = xEventGroupWaitBits(g_events, kGotIp | kDisconnected, pdTRUE, pdFALSE, deadline - now);
        if (bits & kGotIp) break;
        if (!(bits & kDisconnected)) break;  // timed out waiting
        std::string reason = WifiError(g_disconnect_reason);
        if (!reason.empty()) {
            err = reason;
            break;
        }
        vTaskDelay(pdMS_TO_TICKS(1000));
    }
    if (!(bits & kGotIp)) {
        std::string msg = err == "wifi_auth"        ? "Wrong Wi-Fi password"
                          : err == "wifi_not_found" ? "Can't find " + req.ssid
                                                    : "The network didn't give the ball an address";
        esp_wifi_disconnect();
        SetStatus("failed", err, msg);
        g_busy = false;
        return;
    }

    SetStatus("claiming", "", "Pairing with Jarvis…");
    store::Pairing pairing;
    std::string err_code, message;
    if (!Link::Get().Claim(req.server, req.code, req.cf_id, req.cf_secret, pairing, err_code, message)) {
        esp_wifi_disconnect();
        SetStatus("failed", err_code, message);
        g_busy = false;
        return;
    }

    // Only now does anything persist.
    SsidManager::GetInstance().AddSsid(req.ssid, req.password);
    store::SavePairing(pairing);
    store::UiSettings ui = store::LoadUi();
    uint32_t rgb;
    if (logic::ParseHexColor(req.accent, rgb)) ui.theme.accent = rgb;
    if (logic::ParseHexColor(req.success, rgb)) ui.theme.success = rgb;
    if (logic::ParseHexColor(req.warning, rgb)) ui.theme.warning = rgb;
    if (logic::ParseHexColor(req.danger, rgb)) ui.theme.danger = rgb;
    ui.timezone = req.timezone;
    ui.tz_posix = req.tz_posix;
    ui.clock_24h = req.clock_24h;
    store::SaveUi(ui);
    SetStatus("paired", "", "Paired ✓");
    ESP_LOGI(TAG, "paired; rebooting in 15 s");
    vTaskDelay(pdMS_TO_TICKS(15000));
    esp_restart();
}

esp_err_t SendJson(httpd_req_t* req, int status, const std::string& json) {
    const char* status_line = status == 200 ? "200 OK" : status == 202 ? "202 Accepted" : status == 409 ? "409 Conflict" : "400 Bad Request";
    httpd_resp_set_status(req, status_line);
    httpd_resp_set_type(req, "application/json");
    return httpd_resp_send(req, json.data(), json.size());
}

esp_err_t HandleInfo(httpd_req_t* req) {
    int level = 0;
    bool charging = false, discharging = false;
    Board::GetInstance().GetBatteryLevel(level, charging, discharging);
    cJSON* root = cJSON_CreateObject();
    cJSON_AddStringToObject(root, "kind", "jarvis_ball");
    cJSON_AddStringToObject(root, "board", "sp-esp32-s3-1.28-box");
    cJSON_AddStringToObject(root, "fw", UserAgent().substr(11).c_str());
    cJSON_AddStringToObject(root, "mac", g_mac12.c_str());
    cJSON_AddNumberToObject(root, "battery", level);
    cJSON_AddBoolToObject(root, "touch", jarvis::Caps().touch_present);
    char* s = cJSON_PrintUnformatted(root);
    std::string json = s;
    cJSON_free(s);
    cJSON_Delete(root);
    return SendJson(req, 200, json);
}

esp_err_t HandleScan(httpd_req_t* req) {
    wifi_scan_config_t cfg = {};
    if (g_busy || esp_wifi_scan_start(&cfg, true) != ESP_OK) return SendJson(req, 409, "{\"error\":\"busy\"}");
    uint16_t count = 0;
    esp_wifi_scan_get_ap_num(&count);
    count = std::min<uint16_t>(count, 40);
    std::vector<wifi_ap_record_t> records(count);
    esp_wifi_scan_get_ap_records(&count, records.data());
    std::sort(records.begin(), records.end(), [](auto& a, auto& b) { return a.rssi > b.rssi; });
    cJSON* root = cJSON_CreateObject();
    cJSON* list = cJSON_AddArrayToObject(root, "networks");
    std::vector<std::string> seen;
    for (auto& r : records) {
        std::string ssid(reinterpret_cast<const char*>(r.ssid));
        if (ssid.empty() || std::find(seen.begin(), seen.end(), ssid) != seen.end()) continue;
        seen.push_back(ssid);
        cJSON* n = cJSON_CreateObject();
        cJSON_AddStringToObject(n, "ssid", ssid.c_str());
        cJSON_AddNumberToObject(n, "rssi", r.rssi);
        cJSON_AddBoolToObject(n, "secure", r.authmode != WIFI_AUTH_OPEN);
        cJSON_AddItemToArray(list, n);
    }
    char* s = cJSON_PrintUnformatted(root);
    std::string json = s;
    cJSON_free(s);
    cJSON_Delete(root);
    return SendJson(req, 200, json);
}

esp_err_t HandleSetup(httpd_req_t* req) {
    if (req->content_len > 4096) return SendJson(req, 400, "{\"error\":\"body: too large\"}");
    std::string body(req->content_len, '\0');
    size_t got = 0;
    while (got < body.size()) {
        int n = httpd_req_recv(req, &body[got], body.size() - got);
        if (n <= 0) return SendJson(req, 400, "{\"error\":\"body: incomplete\"}");
        got += n;
    }
    if (g_busy) return SendJson(req, 409, "{\"error\":\"a setup attempt is already running\"}");
    logic::SetupRequest parsed;
    std::string err = logic::ParseSetupRequest(body.c_str(), parsed);
    if (!err.empty()) {
        cJSON* e = cJSON_CreateObject();
        cJSON_AddStringToObject(e, "error", err.c_str());
        char* s = cJSON_PrintUnformatted(e);
        std::string json = s;
        cJSON_free(s);
        cJSON_Delete(e);
        return SendJson(req, 400, json);
    }
    g_request = parsed;
    g_busy = true;
    xTaskCreate([](void*) {
        Attempt();
        vTaskDelete(nullptr);
    }, "jarvis_setup", 10240, nullptr, 4, nullptr);
    return SendJson(req, 202, "{\"ok\":true}");
}

esp_err_t HandleStatus(httpd_req_t* req) {
    std::lock_guard<std::mutex> lock(g_status_mutex);
    return SendJson(req, 200, logic::SetupStatusJson(g_state, g_error, g_message));
}

}  // namespace

Setup& Setup::Get() {
    static Setup setup;
    return setup;
}

void Setup::Start() {
    g_events = xEventGroupCreate();
    uint8_t mac[6] = {0};
    esp_read_mac(mac, ESP_MAC_WIFI_STA);
    g_mac12 = logic::Mac12(mac);
    std::string ssid = logic::ApSsid(mac);
    uint8_t rnd[12];
    esp_fill_random(rnd, sizeof(rnd));
    std::string pw = logic::MakePassphrase(rnd, sizeof(rnd));

    ESP_ERROR_CHECK(esp_netif_init());
    esp_err_t err = esp_event_loop_create_default();
    if (err != ESP_OK && err != ESP_ERR_INVALID_STATE) ESP_ERROR_CHECK(err);
    esp_netif_create_default_wifi_ap();
    g_sta = esp_netif_create_default_wifi_sta();
    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&cfg));
    esp_wifi_set_storage(WIFI_STORAGE_RAM);
    esp_event_handler_register(WIFI_EVENT, WIFI_EVENT_STA_DISCONNECTED, &OnWifiEvent, nullptr);
    esp_event_handler_register(IP_EVENT, IP_EVENT_STA_GOT_IP, &OnWifiEvent, nullptr);

    wifi_config_t ap = {};
    strncpy(reinterpret_cast<char*>(ap.ap.ssid), ssid.c_str(), sizeof(ap.ap.ssid));
    ap.ap.ssid_len = ssid.size();
    strncpy(reinterpret_cast<char*>(ap.ap.password), pw.c_str(), sizeof(ap.ap.password));
    ap.ap.authmode = WIFI_AUTH_WPA2_PSK;
    ap.ap.max_connection = 2;
    ap.ap.channel = 1;
    esp_wifi_set_mode(WIFI_MODE_APSTA);
    esp_wifi_set_config(WIFI_IF_AP, &ap);
    ESP_ERROR_CHECK(esp_wifi_start());
    esp_netif_set_default_netif(g_sta);

    httpd_config_t http = HTTPD_DEFAULT_CONFIG();
    http.stack_size = 8192;
    http.max_uri_handlers = 6;
    httpd_handle_t server = nullptr;
    ESP_ERROR_CHECK(httpd_start(&server, &http));
    httpd_uri_t routes[] = {
        {.uri = "/jarvis/info", .method = HTTP_GET, .handler = HandleInfo, .user_ctx = nullptr},
        {.uri = "/jarvis/wifi/scan", .method = HTTP_GET, .handler = HandleScan, .user_ctx = nullptr},
        {.uri = "/jarvis/setup", .method = HTTP_POST, .handler = HandleSetup, .user_ctx = nullptr},
        {.uri = "/jarvis/setup/status", .method = HTTP_GET, .handler = HandleStatus, .user_ctx = nullptr},
    };
    for (auto& r : routes) httpd_register_uri_handler(server, &r);

    Ui::Get().ShowSetup(logic::SetupQrPayload(ssid, pw, g_mac12), ssid);
    ESP_LOGI(TAG, "setup hotspot %s up", ssid.c_str());
}

}  // namespace jarvis
