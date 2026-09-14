#include "jarvis_link.h"

#include <cJSON.h>
#include <esp_app_desc.h>
#include <esp_log.h>
#include <esp_mac.h>
#include <esp_random.h>
#include <esp_timer.h>
#include <freertos/FreeRTOS.h>
#include <freertos/queue.h>
#include <freertos/task.h>
#include <web_socket.h>

#include "board.h"
#include "jarvis/logic/jarvis_logic.h"

#define TAG "JarvisLink"

namespace jarvis {

static int64_t NowMs() { return esp_timer_get_time() / 1000; }

std::string UserAgent() { return std::string("JarvisBall/") + esp_app_get_description()->version; }

HttpResult HttpRequest(const std::string& method, const std::string& url, const std::string& body,
                       const store::Pairing& auth, bool with_cookie, int timeout_ms) {
    HttpResult out;
    auto http = Board::GetInstance().GetNetwork()->CreateHttp(0);
    if (!http) {
        out.error = "no network";
        return out;
    }
    http->SetTimeout(timeout_ms);
    http->SetHeader("User-Agent", UserAgent());
    if (!auth.cf_id.empty()) {
        http->SetHeader("CF-Access-Client-Id", auth.cf_id);
        http->SetHeader("CF-Access-Client-Secret", auth.cf_secret);
    }
    if (with_cookie && !auth.cookie.empty()) http->SetHeader("Cookie", auth.cookie);
    if (!body.empty()) {
        http->SetHeader("Content-Type", "application/json");
        http->SetContent(std::string(body));
    }
    if (!http->Open(method, url)) {
        out.error = "could not connect";
        return out;
    }
    auto status = http->GetStatusCode();
    if (!status) {
        out.error = "no response";
        http->Close();
        return out;
    }
    out.status = *status;
    std::string cookie = http->GetResponseHeader("Set-Cookie");
    out.set_cookie = cookie.substr(0, cookie.find(';'));
    out.body = http->ReadAll();
    http->Close();
    return out;
}

void ApplyAuthHeaders(WebSocket& ws, const store::Pairing& auth) {
    ws.SetHeader("User-Agent", UserAgent().c_str());
    if (!auth.cookie.empty()) ws.SetHeader("Cookie", auth.cookie.c_str());
    if (!auth.cf_id.empty()) {
        ws.SetHeader("CF-Access-Client-Id", auth.cf_id.c_str());
        ws.SetHeader("CF-Access-Client-Secret", auth.cf_secret.c_str());
    }
}

// ---- registry ---------------------------------------------------------------

void ToolRegistry::Add(const char* name, const char* description, const char* input_schema_json,
                       ToolHandler handler) {
    cJSON* schema = cJSON_Parse(input_schema_json);
    if (!schema) {
        ESP_LOGE(TAG, "bad schema for %s", name);
        schema = cJSON_Parse("{\"type\":\"object\",\"properties\":{}}");
    }
    tools_.push_back(Tool{name, description, schema, std::move(handler)});
}

std::string ToolRegistry::RegisterMessage() const {
    cJSON* msg = cJSON_CreateObject();
    cJSON_AddStringToObject(msg, "type", "register");
    cJSON* skills = cJSON_AddArrayToObject(msg, "skills");
    for (auto& t : tools_) {
        cJSON* s = cJSON_CreateObject();
        cJSON_AddStringToObject(s, "name", t.name.c_str());
        cJSON_AddStringToObject(s, "description", t.description.c_str());
        cJSON_AddItemToObject(s, "input_schema", cJSON_Duplicate(t.schema, true));
        cJSON_AddItemToArray(skills, s);
    }
    char* text = cJSON_PrintUnformatted(msg);
    std::string out = text ? text : "";
    cJSON_free(text);
    cJSON_Delete(msg);
    return out;
}

std::string ToolRegistry::Invoke(const std::string& name, const cJSON* args, cJSON* result) const {
    for (auto& t : tools_) {
        if (t.name != name) continue;
        std::string err = logic::ValidateArgs(t.schema, args);
        if (!err.empty()) return err;
        return t.handler(args, result);
    }
    return "unknown skill: " + name;
}

ToolRegistry& Tools() {
    static ToolRegistry registry;
    return registry;
}

// ---- link -------------------------------------------------------------------

Link& Link::Get() {
    static Link link;
    return link;
}

bool Link::Claim(const std::string& server, const std::string& code, const std::string& cf_id,
                 const std::string& cf_secret, store::Pairing& out, std::string& err_code, std::string& message) {
    store::Pairing auth{server, "", cf_id, cf_secret};
    uint8_t mac[6] = {0};
    esp_read_mac(mac, ESP_MAC_WIFI_STA);
    cJSON* body = cJSON_CreateObject();
    cJSON_AddStringToObject(body, "code", code.c_str());
    cJSON_AddStringToObject(body, "name", ("Jarvis Ball " + logic::ApSsid(mac).substr(7)).c_str());
    char* text = cJSON_PrintUnformatted(body);
    std::string json = text ? text : "{}";
    cJSON_free(text);
    cJSON_Delete(body);

    HttpResult r = HttpRequest("POST", logic::JoinUrl(server, "/api/auth/pair/claim"), json, auth, false);
    if (!r.error.empty() || r.status >= 500 || r.status < 0) {
        err_code = "server_unreachable";
        message = "The ball reached Wi-Fi but not Jarvis";
        return false;
    }
    if (r.status != 200 || r.set_cookie.empty()) {
        err_code = "code_rejected";
        message = "Jarvis rejected the pairing code";
        return false;
    }
    out = auth;
    out.cookie = r.set_cookie;
    cJSON* reply = cJSON_Parse(r.body.c_str());
    const cJSON* cf = cJSON_GetObjectItemCaseSensitive(reply, "cf_access");
    const cJSON* id = cJSON_GetObjectItemCaseSensitive(cf, "client_id");
    const cJSON* secret = cJSON_GetObjectItemCaseSensitive(cf, "client_secret");
    if (cJSON_IsString(id) && cJSON_IsString(secret) && id->valuestring[0]) {
        out.cf_id = id->valuestring;
        out.cf_secret = secret->valuestring;
    }
    cJSON_Delete(reply);
    return true;
}

void Link::SetState(LinkState s) {
    if (state_.exchange(s) != s && on_state) on_state(s);
}

void Link::Start() {
    if (started_.exchange(true)) return;
    invoke_queue_ = xQueueCreate(8, sizeof(std::string*));
    xTaskCreate([](void* self) { static_cast<Link*>(self)->Run(); }, "jarvis_link", 8192, this, 4, nullptr);
    xTaskCreate([](void* self) { static_cast<Link*>(self)->Worker(); }, "jarvis_tools", 12288, this, 3, nullptr);
}

void Link::SendJson(cJSON* msg) {
    char* text = cJSON_PrintUnformatted(msg);
    cJSON_Delete(msg);
    if (!text) return;
    {
        std::lock_guard<std::mutex> lock(ws_mutex_);
        if (ws_ && ws_->IsConnected()) ws_->Send(std::string(text));
    }
    cJSON_free(text);
}

void Link::HandleText(const std::string& text) {
    last_rx_ms_ = NowMs();
    cJSON* msg = cJSON_Parse(text.c_str());
    const cJSON* type = cJSON_GetObjectItemCaseSensitive(msg, "type");
    if (!cJSON_IsString(type)) {
        cJSON_Delete(msg);
        return;
    }
    std::string t = type->valuestring;
    cJSON_Delete(msg);
    if (t == "hello") {
        std::string reg = Tools().RegisterMessage();
        std::lock_guard<std::mutex> lock(ws_mutex_);
        if (ws_) ws_->Send(reg);
        ESP_LOGI(TAG, "bridge up, skills registered");
    } else if (t == "ping") {
        std::lock_guard<std::mutex> lock(ws_mutex_);
        if (ws_) ws_->Send(std::string("{\"type\":\"pong\"}"));
    } else if (t == "invoke") {
        auto* copy = new std::string(text);
        if (xQueueSend(static_cast<QueueHandle_t>(invoke_queue_), &copy, 0) != pdTRUE) {
            delete copy;
            ESP_LOGW(TAG, "invoke queue full");
        }
    }
}

void Link::Worker() {
    for (;;) {
        std::string* raw = nullptr;
        if (xQueueReceive(static_cast<QueueHandle_t>(invoke_queue_), &raw, portMAX_DELAY) != pdTRUE) continue;
        cJSON* msg = cJSON_Parse(raw->c_str());
        delete raw;
        const cJSON* call_id = cJSON_GetObjectItemCaseSensitive(msg, "call_id");
        const cJSON* skill = cJSON_GetObjectItemCaseSensitive(msg, "skill");
        const cJSON* args = cJSON_GetObjectItemCaseSensitive(msg, "args");
        if (cJSON_IsString(call_id) && cJSON_IsString(skill)) {
            cJSON* result = cJSON_CreateObject();
            std::string err = Tools().Invoke(skill->valuestring, cJSON_IsObject(args) ? args : nullptr, result);
            cJSON* reply = cJSON_CreateObject();
            cJSON_AddStringToObject(reply, "call_id", call_id->valuestring);
            if (err.empty()) {
                cJSON_AddStringToObject(reply, "type", "result");
                cJSON_AddItemToObject(reply, "result", result);
            } else {
                cJSON_AddStringToObject(reply, "type", "error");
                cJSON_AddStringToObject(reply, "error", err.c_str());
                cJSON_Delete(result);
            }
            SendJson(reply);
        }
        cJSON_Delete(msg);
    }
}

void Link::Run() {
    int attempt = 0;
    int quick_closes = 0;
    for (;;) {
        store::Pairing pairing = store::LoadPairing();
        if (!pairing.paired()) {
            SetState(LinkState::Unpaired);
            vTaskDelay(portMAX_DELAY);
            continue;
        }
        SetState(LinkState::Connecting);
        auto ws = Board::GetInstance().GetNetwork()->CreateWebSocket(1);
        ApplyAuthHeaders(*ws, pairing);
        ws->SetReceiveBufferSize(32 * 1024);
        closed_ = false;
        ws->OnData([this](const char* data, size_t len, bool binary) {
            if (!binary) HandleText(std::string(data, len));
        });
        ws->OnDisconnected([this]() { closed_ = true; });
        int64_t opened = NowMs();
        std::string url = logic::WsUrl(pairing.server, "/api/devices/bridge/ws");
        if (ws->Connect(url.c_str())) {
            {
                std::lock_guard<std::mutex> lock(ws_mutex_);
                ws_ = ws.get();
            }
            last_rx_ms_ = NowMs();
            SetState(LinkState::Connected);
            int64_t last_ping = NowMs();
            while (!closed_ && ws->IsConnected()) {
                vTaskDelay(pdMS_TO_TICKS(1000));
                int64_t now = NowMs();
                if (now - last_rx_ms_ > 90000) {
                    ESP_LOGW(TAG, "bridge silent for 90 s, reconnecting");
                    break;
                }
                if (now - last_ping >= 30000) {
                    last_ping = now;
                    std::lock_guard<std::mutex> lock(ws_mutex_);
                    ws->Send(std::string("{\"type\":\"ping\"}"));
                }
            }
            std::lock_guard<std::mutex> lock(ws_mutex_);
            ws_ = nullptr;
        }
        ws->Close();
        ws.reset();
        SetState(LinkState::Offline);

        if (NowMs() - opened < 5000) {
            if (++quick_closes >= 3) {
                quick_closes = 0;
                HttpResult probe = HttpRequest("GET", logic::JoinUrl(pairing.server, "/api/devices"), "", pairing, true, 10000);
                if (probe.status == 401 || probe.status == 403) {
                    ESP_LOGW(TAG, "server revoked this ball");
                    SetState(LinkState::Unpaired);
                    vTaskDelay(portMAX_DELAY);
                }
            }
        } else {
            quick_closes = 0;
            attempt = 0;
        }
        int delay_ms = logic::BackoffSeconds(attempt++) * 1000;
        delay_ms += static_cast<int>(esp_random() % (delay_ms / 5 + 1)) - delay_ms / 10;
        vTaskDelay(pdMS_TO_TICKS(delay_ms));
    }
}

}  // namespace jarvis
