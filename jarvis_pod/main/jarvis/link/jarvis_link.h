// The pod's side of Jarvis's existing protocols: the pairing claim and the device
// bridge (webui/api/device_bridge.py). Skills registered here become the agent's
// device_pod_* tools.
#pragma once

#include <atomic>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include "jarvis/store/jarvis_store.h"

struct cJSON;
class WebSocket;

namespace jarvis {

std::string UserAgent();

struct HttpResult {
    int status = -1;
    std::string body;
    std::string set_cookie;  // "name=value" only
    std::string error;       // transport failure, empty when a response arrived
};

// `with_cookie` false for the claim (no session yet). Credentials are only ever sent
// to the paired server's own host (callers pass that server's URLs).
// `max_body` > 0 stops reading (and fails) once the body would exceed it.
HttpResult HttpRequest(const std::string& method, const std::string& url, const std::string& body,
                       const store::Pairing& auth, bool with_cookie, int timeout_ms = 15000, size_t max_body = 0);

void ApplyAuthHeaders(WebSocket& ws, const store::Pairing& auth);

// Downloads a page's https images (≤ 100 KB each). Jarvis credentials go only to the
// paired server's own host.
std::map<std::string, std::string> FetchPageImages(const cJSON* page);

// A handler fills `result` (owned by the caller) and returns "" or an error message.
using ToolHandler = std::function<std::string(const cJSON* args, cJSON* result)>;

class ToolRegistry {
public:
    void Add(const char* name, const char* description, const char* input_schema_json, ToolHandler handler);
    std::string RegisterMessage() const;  // {"type":"register","skills":[…]}
    // Validates args against the schema, then runs the handler.
    std::string Invoke(const std::string& name, const cJSON* args, cJSON* result) const;

private:
    struct Tool {
        std::string name, description;
        cJSON* schema;
        ToolHandler handler;
    };
    std::vector<Tool> tools_;
};

ToolRegistry& Tools();
void RegisterPodTools();  // jarvis_tools.cc

enum class LinkState { Offline, Connecting, Connected, Unpaired };

class Link {
public:
    static Link& Get();

    // Setup: claim `code` on `server`. On success `out` holds the pairing to save.
    // err_code is "code_rejected" or "server_unreachable".
    bool Claim(const std::string& server, const std::string& code, const std::string& cf_id,
               const std::string& cf_secret, store::Pairing& out, std::string& err_code, std::string& message);

    void Start();  // idempotent; call once Wi-Fi has an IP
    LinkState state() const { return state_.load(); }
    std::function<void(LinkState)> on_state;  // called from the link task

private:
    void Run();
    void Worker();
    void HandleText(const std::string& text);
    void SetState(LinkState s);
    void SendJson(cJSON* msg);  // takes ownership

    std::atomic<LinkState> state_{LinkState::Offline};
    std::atomic<bool> started_{false};
    std::atomic<bool> closed_{false};
    // Replies owed to the server, sent from Run(): the socket's receive task has a
    // small stack and fires before ws_ is published.
    std::atomic<bool> register_pending_{false};
    std::atomic<bool> pong_pending_{false};
    std::atomic<int64_t> last_rx_ms_{0};
    std::mutex ws_mutex_;
    WebSocket* ws_ = nullptr;
    void* invoke_queue_ = nullptr;  // QueueHandle_t of std::string* (the invoke JSON)
};

}  // namespace jarvis
