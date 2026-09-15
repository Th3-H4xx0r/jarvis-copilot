#include "jarvis_link.h"

#include <cJSON.h>
#include <esp_app_desc.h>
#include <esp_crt_bundle.h>
#include <esp_http_client.h>
#include <strings.h>
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

static HttpResult HttpOnce(const std::string& method, const std::string& url, const std::string& body,
                           const store::Pairing& auth, bool with_cookie, int timeout_ms, size_t max_body,
                           std::string* redirect);

HttpResult HttpRequest(const std::string& method, const std::string& url, const std::string& body,
                       const store::Pairing& auth, bool with_cookie, int timeout_ms, size_t max_body) {
    // Image links on the web usually redirect (CDNs, wiki "Special:FilePath"); follow GETs.
    std::string target = url;
    for (int hop = 0; hop < 4; ++hop) {
        std::string next;
        HttpResult r = HttpOnce(method, target, body, auth, with_cookie, timeout_ms, max_body,
                                method == "GET" ? &next : nullptr);
        if (next.empty()) return r;
        // Credentials never follow a redirect to another host.
        auto host = [](const std::string& u) { size_t s = u.find("://"); return s == std::string::npos ? u : u.substr(0, u.find('/', s + 3)); };
        if (next.rfind("/", 0) == 0) next = host(target) + next;
        if (host(next) != host(target)) with_cookie = false;
        target = next;
    }
    HttpResult out;
    out.error = "too many redirects";
    return out;
}

static HttpResult HttpOnce(const std::string& method, const std::string& url, const std::string& body,
                           const store::Pairing& auth, bool with_cookie, int timeout_ms, size_t max_body,
                           std::string* redirect) {
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
    if (redirect && out.status >= 301 && out.status <= 308 && out.status != 304) {
        *redirect = http->GetResponseHeader("Location");
        if (!redirect->empty()) {
            http->Close();
            return out;
        }
    }
    std::string cookie = http->GetResponseHeader("Set-Cookie");
    out.set_cookie = cookie.substr(0, cookie.find(';'));
    if (max_body > 0) {
        if (http->GetBodyLength() > max_body) {
            out.error = "response too large";
            http->Close();
            return out;
        }
        char buf[1024];
        for (;;) {  // chunked bodies report no length: cap while reading
            auto n = http->Read(buf, sizeof(buf));
            if (!n || *n <= 0) break;
            out.body.append(buf, *n);
            if (out.body.size() > max_body) {
                out.body.clear();
                out.error = "response too large";
                break;
            }
        }
    } else {
        out.body = http->ReadAll();
    }
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

    // esp_http_client rather than HttpRequest: the response can carry several Set-Cookie
    // headers (Cloudflare adds its own) and only this client shows us every one of them.
    struct ClaimCtx {
        std::string session_cookie;
        std::string body;
    } ctx;
    esp_http_client_config_t cfg = {};
    std::string url = logic::JoinUrl(server, "/api/auth/pair/claim");
    cfg.url = url.c_str();
    cfg.method = HTTP_METHOD_POST;
    cfg.timeout_ms = 15000;
    cfg.crt_bundle_attach = esp_crt_bundle_attach;
    cfg.user_data = &ctx;
    cfg.event_handler = [](esp_http_client_event_t* e) -> esp_err_t {
        auto* c = static_cast<ClaimCtx*>(e->user_data);
        if (e->event_id == HTTP_EVENT_ON_HEADER && strcasecmp(e->header_key, "Set-Cookie") == 0) {
            std::string value = e->header_value;
            std::string pair = value.substr(0, value.find(';'));
            if (pair.rfind("hermes_session=", 0) == 0) c->session_cookie = pair;
        } else if (e->event_id == HTTP_EVENT_ON_DATA && c->body.size() < 8192) {
            c->body.append(static_cast<const char*>(e->data), e->data_len);
        }
        return ESP_OK;
    };
    esp_http_client_handle_t client = esp_http_client_init(&cfg);
    esp_http_client_set_header(client, "Content-Type", "application/json");
    esp_http_client_set_header(client, "User-Agent", UserAgent().c_str());
    if (!cf_id.empty()) {
        esp_http_client_set_header(client, "CF-Access-Client-Id", cf_id.c_str());
        esp_http_client_set_header(client, "CF-Access-Client-Secret", cf_secret.c_str());
    }
    esp_http_client_set_post_field(client, json.c_str(), json.size());
    esp_err_t err = esp_http_client_perform(client);
    int status = err == ESP_OK ? esp_http_client_get_status_code(client) : -1;
    esp_http_client_cleanup(client);
    if (status < 0 || status >= 500) {
        err_code = "server_unreachable";
        message = "The ball reached Wi-Fi but not Jarvis";
        return false;
    }
    if (status != 200 || ctx.session_cookie.empty()) {
        err_code = "code_rejected";
        message = "Jarvis rejected the pairing code";
        return false;
    }
    out = auth;
    out.cookie = ctx.session_cookie;
    cJSON* reply = cJSON_Parse(ctx.body.c_str());
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
        register_pending_ = true;
    } else if (t == "ping") {
        pong_pending_ = true;
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
        register_pending_ = false;
        pong_pending_ = false;
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
                vTaskDelay(pdMS_TO_TICKS(100));
                if (register_pending_.exchange(false)) {
                    std::string reg = Tools().RegisterMessage();
                    std::lock_guard<std::mutex> lock(ws_mutex_);
                    ws->Send(reg);
                    ESP_LOGI(TAG, "bridge up, skills registered");
                }
                if (pong_pending_.exchange(false)) {
                    std::lock_guard<std::mutex> lock(ws_mutex_);
                    ws->Send(std::string("{\"type\":\"pong\"}"));
                }
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
