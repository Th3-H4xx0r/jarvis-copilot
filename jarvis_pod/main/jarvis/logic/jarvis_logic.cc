#include "jarvis_logic.h"

#include <cJSON.h>

#include <algorithm>
#include <cstdio>
#include <cstring>

namespace jarvis::logic {

const char kCodeAlphabet[] = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";

std::string MakePassphrase(const uint8_t* random_bytes, size_t n) {
    const size_t len = sizeof(kCodeAlphabet) - 1;
    std::string out;
    for (size_t i = 0; i < 12 && i < n; ++i) out.push_back(kCodeAlphabet[random_bytes[i] % len]);
    return out;
}

static std::string UrlEncode(const std::string& s) {
    static const char* hex = "0123456789ABCDEF";
    std::string out;
    for (unsigned char c : s) {
        if (isalnum(c) || c == '-' || c == '_' || c == '.' || c == '~') {
            out.push_back(static_cast<char>(c));
        } else {
            out.push_back('%');
            out.push_back(hex[c >> 4]);
            out.push_back(hex[c & 15]);
        }
    }
    return out;
}

std::string SetupQrPayload(const std::string& ssid, const std::string& passphrase, const std::string& mac12) {
    return "jarviscopilot://device-setup?v=1&kind=jarvis_pod&ssid=" + UrlEncode(ssid) +
           "&pw=" + UrlEncode(passphrase) + "&id=" + UrlEncode(mac12);
}

std::string ApSsid(const uint8_t mac[6]) {
    char buf[16];
    snprintf(buf, sizeof(buf), "Jarvis-%02X%02X", mac[4], mac[5]);
    return buf;
}

std::string Mac12(const uint8_t mac[6]) {
    char buf[13];
    snprintf(buf, sizeof(buf), "%02x%02x%02x%02x%02x%02x", mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
    return buf;
}

std::string SetupStatusJson(const std::string& state, const std::string& error, const std::string& message) {
    cJSON* root = cJSON_CreateObject();
    cJSON_AddStringToObject(root, "state", state.c_str());
    cJSON_AddStringToObject(root, "error", error.c_str());
    cJSON_AddStringToObject(root, "message", message.c_str());
    char* s = cJSON_PrintUnformatted(root);
    std::string out = s ? s : "{}";
    cJSON_free(s);
    cJSON_Delete(root);
    return out;
}

static bool GetStr(const cJSON* obj, const char* key, std::string& out, size_t max_len, bool required,
                   const std::string& path, std::string& err) {
    const cJSON* v = cJSON_GetObjectItemCaseSensitive(obj, key);
    if (!v) {
        if (required) err = path + key + ": required";
        return !required;
    }
    if (!cJSON_IsString(v) || !v->valuestring) {
        err = path + key + ": must be a string";
        return false;
    }
    if (strlen(v->valuestring) > max_len) {
        err = path + key + ": too long";
        return false;
    }
    out = v->valuestring;
    return true;
}

std::string ParseSetupRequest(const char* body, SetupRequest& out) {
    cJSON* root = cJSON_Parse(body ? body : "");
    if (!cJSON_IsObject(root)) {
        cJSON_Delete(root);
        return "body: not a JSON object";
    }
    std::string err;
    const cJSON* wifi = cJSON_GetObjectItemCaseSensitive(root, "wifi");
    const cJSON* cf = cJSON_GetObjectItemCaseSensitive(root, "cf_access");
    const cJSON* theme = cJSON_GetObjectItemCaseSensitive(root, "theme");
    bool ok = true;
    if (!cJSON_IsObject(wifi)) {
        err = "wifi: required";
        ok = false;
    }
    ok = ok && GetStr(wifi, "ssid", out.ssid, 32, true, "wifi.", err) &&
         GetStr(wifi, "password", out.password, 64, false, "wifi.", err) &&
         GetStr(root, "server", out.server, 200, true, "", err) &&
         GetStr(root, "code", out.code, 16, true, "", err) &&
         GetStr(root, "timezone", out.timezone, 64, false, "", err) &&
         GetStr(root, "tz_posix", out.tz_posix, 64, false, "", err);
    if (ok && cJSON_IsObject(cf)) {
        ok = GetStr(cf, "client_id", out.cf_id, 256, false, "cf_access.", err) &&
             GetStr(cf, "client_secret", out.cf_secret, 256, false, "cf_access.", err);
    }
    if (ok && cJSON_IsObject(theme)) {
        ok = GetStr(theme, "accent", out.accent, 7, false, "theme.", err) &&
             GetStr(theme, "success", out.success, 7, false, "theme.", err) &&
             GetStr(theme, "warning", out.warning, 7, false, "theme.", err) &&
             GetStr(theme, "danger", out.danger, 7, false, "theme.", err);
    }
    if (ok && out.ssid.empty()) {
        err = "wifi.ssid: required";
        ok = false;
    }
    if (ok && out.server.rfind("http://", 0) != 0 && out.server.rfind("https://", 0) != 0) {
        err = "server: must start with http:// or https://";
        ok = false;
    }
    if (ok) {
        const cJSON* c24 = cJSON_GetObjectItemCaseSensitive(root, "clock_24h");
        out.clock_24h = cJSON_IsTrue(c24);
    }
    cJSON_Delete(root);
    return ok ? "" : err;
}

int BackoffSeconds(int attempt) {
    if (attempt < 0) attempt = 0;
    if (attempt >= 6) return 60;
    return std::min(60, 1 << attempt);
}

static std::string TrimSlash(std::string s) {
    while (!s.empty() && s.back() == '/') s.pop_back();
    return s;
}

std::string JoinUrl(const std::string& server, const std::string& path) {
    return TrimSlash(server) + path;
}

std::string WsUrl(const std::string& server, const std::string& path) {
    std::string s = TrimSlash(server);
    if (s.rfind("https://", 0) == 0) s = "wss://" + s.substr(8);
    else if (s.rfind("http://", 0) == 0) s = "ws://" + s.substr(7);
    return s + path;
}

static bool TypeMatches(const char* type, const cJSON* v) {
    if (!strcmp(type, "string")) return cJSON_IsString(v);
    if (!strcmp(type, "boolean")) return cJSON_IsBool(v);
    if (!strcmp(type, "object")) return cJSON_IsObject(v);
    if (!strcmp(type, "array")) return cJSON_IsArray(v);
    if (!strcmp(type, "number")) return cJSON_IsNumber(v);
    if (!strcmp(type, "integer")) return cJSON_IsNumber(v) && v->valuedouble == static_cast<double>(static_cast<long long>(v->valuedouble));
    return true;
}

std::string ValidateArgs(const cJSON* schema, const cJSON* args) {
    if (args && !cJSON_IsObject(args)) return "args: must be an object";
    const cJSON* required = cJSON_GetObjectItemCaseSensitive(schema, "required");
    const cJSON* item;
    cJSON_ArrayForEach(item, required) {
        if (cJSON_IsString(item) && !cJSON_GetObjectItemCaseSensitive(args, item->valuestring)) {
            return std::string(item->valuestring) + ": required";
        }
    }
    const cJSON* props = cJSON_GetObjectItemCaseSensitive(schema, "properties");
    const cJSON* prop;
    cJSON_ArrayForEach(prop, props) {
        const cJSON* v = cJSON_GetObjectItemCaseSensitive(args, prop->string);
        const cJSON* type = cJSON_GetObjectItemCaseSensitive(prop, "type");
        if (v && cJSON_IsString(type) && !TypeMatches(type->valuestring, v)) {
            return std::string(prop->string) + ": must be " + type->valuestring;
        }
    }
    return "";
}

bool ParseHexColor(const std::string& s, uint32_t& out) {
    if (s.size() != 7 || s[0] != '#') return false;
    uint32_t v = 0;
    for (size_t i = 1; i < 7; ++i) {
        char c = s[i];
        v <<= 4;
        if (c >= '0' && c <= '9') v |= c - '0';
        else if (c >= 'a' && c <= 'f') v |= c - 'a' + 10;
        else if (c >= 'A' && c <= 'F') v |= c - 'A' + 10;
        else return false;
    }
    out = v;
    return true;
}

// ---- pages -----------------------------------------------------------------

static const char* kSymbolNames[] = {
#define SYM(name, lv) name,
#include "symbols.def"
#undef SYM
};

const char* SymbolGlyph(const std::string& sf_name) {
    for (const char* n : kSymbolNames) {
        if (sf_name == n) return n;
    }
    return nullptr;
}

static size_t EditDistance(const std::string& a, const std::string& b) {
    std::vector<size_t> prev(b.size() + 1), cur(b.size() + 1);
    for (size_t j = 0; j <= b.size(); ++j) prev[j] = j;
    for (size_t i = 1; i <= a.size(); ++i) {
        cur[0] = i;
        for (size_t j = 1; j <= b.size(); ++j) {
            cur[j] = std::min({prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] != b[j - 1])});
        }
        prev.swap(cur);
    }
    return prev[b.size()];
}

std::vector<std::string> NearSymbols(const std::string& sf_name) {
    std::vector<std::pair<size_t, std::string>> scored;
    for (const char* n : kSymbolNames) scored.emplace_back(EditDistance(sf_name, n), n);
    std::sort(scored.begin(), scored.end());
    std::vector<std::string> out;
    for (size_t i = 0; i < scored.size() && out.size() < 3; ++i) out.push_back(scored[i].second);
    return out;
}

bool IsBuiltinHome(const std::string& id) { return id == "orb" || id == "clock"; }

bool IsStopPhrase(const std::string& transcript) {
    // Lowercase words; apostrophes (ASCII or U+2019) dropped so "that's" == "thats".
    std::vector<std::string> words;
    std::string w;
    for (size_t i = 0; i <= transcript.size(); ++i) {
        unsigned char c = i < transcript.size() ? static_cast<unsigned char>(transcript[i]) : ' ';
        if (c == 0xE2 && i + 2 < transcript.size() && static_cast<unsigned char>(transcript[i + 1]) == 0x80 &&
            static_cast<unsigned char>(transcript[i + 2]) == 0x99) {
            i += 2;
            continue;
        }
        if (c == '\'') continue;
        if (isalpha(c)) {
            w.push_back(static_cast<char>(tolower(c)));
        } else if (!w.empty()) {
            words.push_back(w);
            w.clear();
        }
    }
    // Edge words that never change the meaning. The second group is only stripped for a
    // second attempt, so "no thanks" still matches as itself.
    static const char* kFillers[] = {"hey", "ok", "okay", "oh", "uh", "um", "hmm", "please", "jarvis",
                                     "so", "well", "yeah"};
    static const char* kCourtesies[] = {"sir", "thanks", "thank", "you", "now", "then", "for", "just",
                                        "actually", "right"};
    auto filler = [](const std::string& s) {
        for (const char* f : kFillers) {
            if (s == f) return true;
        }
        return false;
    };
    while (!words.empty() && filler(words.front())) words.erase(words.begin());
    while (!words.empty() && filler(words.back())) words.pop_back();
    // Trailing courtesies and time words ("for now", "then", "thanks") are already out as
    // fillers; what remains is the phrase itself.
    // "stop stop", "never mind never mind": one copy.
    for (size_t n = 1; n <= words.size() / 2; ++n) {
        if (words.size() % n) continue;
        bool repeats = true;
        for (size_t i = n; i < words.size() && repeats; ++i) repeats = words[i] == words[i % n];
        if (repeats) {
            words.resize(n);
            break;
        }
    }
    auto joined = [](const std::vector<std::string>& ws) {
        std::string out;
        for (auto& w : ws) out += (out.empty() ? "" : " ") + w;
        return out;
    };
    std::vector<std::string> tight = words;
    auto courtesy = [](const std::string& s) {
        for (const char* f : kCourtesies) {
            if (s == f) return true;
        }
        return false;
    };
    while (!tight.empty() && courtesy(tight.back())) tight.pop_back();
    while (!tight.empty() && courtesy(tight.front())) tight.erase(tight.begin());
    const std::string t = joined(words);
    const std::string t2 = joined(tight);
    static const char* kStops[] = {
        "stop", "stop listening", "stop it", "nothing", "nothing else", "no nothing", "never mind", "nevermind",
        "cancel", "cancel that", "thats all", "thats it", "thats enough", "thatll be all", "that will be all",
        "that would be all", "no thats all", "no thats it", "goodbye", "good bye", "bye", "no thanks",
        "no thank you", "im done", "im good", "im all set", "all set", "all good", "we are done", "were done",
        "all done", "done", "forget it", "be quiet", "quiet", "shut up", "go to sleep", "sleep", "dismiss",
        "exit", "nah", "nope"};  // not bare "no" — that answers a question
    for (const char* s : kStops) {
        if (t == s || t2 == s) return true;
    }
    return false;
}

bool ValidPageId(const std::string& id) {
    // "/pages/<id>.json" must fit SPIFFS's 31-char object names.
    if (id.empty() || id.size() > 20) return false;
    return std::all_of(id.begin(), id.end(), [](char c) {
        return (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '-';
    });
}

static const char* kColorTokens[] = {"accent", "success", "warning", "danger", "text", "muted", "bg"};

namespace {

struct PageCheck {
    std::vector<std::string> errors;
    int nodes = 0;

    void Add(const std::string& path, const std::string& msg) {
        if (errors.size() < 20) errors.push_back(path + ": " + msg);
    }

    static bool IsBinding(const cJSON* v) {
        const cJSON* key = cJSON_GetObjectItemCaseSensitive(v, "$");
        return cJSON_IsObject(v) && cJSON_IsString(key) && key->valuestring[0];
    }

    // A scalar value or a {"$": key} binding.
    void Value(const cJSON* node, const char* key, const std::string& path, bool required) {
        const cJSON* v = cJSON_GetObjectItemCaseSensitive(node, key);
        if (!v) {
            if (required) Add(path + "." + key, "required");
            return;
        }
        if (!(cJSON_IsString(v) || cJSON_IsNumber(v) || IsBinding(v))) {
            Add(path + "." + key, "must be a string, number or {\"$\": key} binding");
        }
    }

    void Style(const cJSON* node, const std::string& path) {
        const cJSON* style = cJSON_GetObjectItemCaseSensitive(node, "style");
        if (!style) return;
        if (!cJSON_IsObject(style)) {
            Add(path + ".style", "must be an object");
            return;
        }
        const cJSON* size = cJSON_GetObjectItemCaseSensitive(style, "size");
        if (size && (!cJSON_IsNumber(size) || size->valuedouble < 12 || size->valuedouble > 64)) {
            Add(path + ".style.size", "must be a number from 12 to 64");
        }
        const cJSON* color = cJSON_GetObjectItemCaseSensitive(style, "color");
        if (color) {
            uint32_t rgb;
            bool ok = cJSON_IsString(color) &&
                      (ParseHexColor(color->valuestring, rgb) ||
                       std::any_of(std::begin(kColorTokens), std::end(kColorTokens),
                                   [&](const char* t) { return !strcmp(t, color->valuestring); }));
            if (!ok) Add(path + ".style.color", "must be accent|success|warning|danger|text|muted|bg or #RRGGBB");
        }
        const cJSON* weight = cJSON_GetObjectItemCaseSensitive(style, "weight");
        if (weight && !(cJSON_IsString(weight) && (!strcmp(weight->valuestring, "regular") || !strcmp(weight->valuestring, "bold")))) {
            Add(path + ".style.weight", "must be regular or bold");
        }
        const cJSON* align = cJSON_GetObjectItemCaseSensitive(style, "align");
        if (align && !(cJSON_IsString(align) && (!strcmp(align->valuestring, "left") || !strcmp(align->valuestring, "center") ||
                                                 !strcmp(align->valuestring, "right") || !strcmp(align->valuestring, "start") ||
                                                 !strcmp(align->valuestring, "end")))) {
            Add(path + ".style.align", "must be left|center|right");
        }
    }

    void OnTap(const cJSON* node, const std::string& path) {
        const cJSON* tap = cJSON_GetObjectItemCaseSensitive(node, "onTap");
        if (!tap) return;
        const cJSON* action = cJSON_GetObjectItemCaseSensitive(tap, "action");
        if (!cJSON_IsObject(tap) || !cJSON_IsString(action)) {
            Add(path + ".onTap", "must be {\"action\": \"voice\"|\"home\"}");
            return;
        }
        if (strcmp(action->valuestring, "voice") && strcmp(action->valuestring, "home")) {
            Add(path + ".onTap.action", "must be voice or home");
        }
        const cJSON* text = cJSON_GetObjectItemCaseSensitive(tap, "text");
        if (text && !(cJSON_IsString(text) && strlen(text->valuestring) <= 200)) {
            Add(path + ".onTap.text", "must be a string of at most 200 chars");
        }
    }

    void Node(const cJSON* node, const std::string& path, int depth) {
        if (++nodes > kMaxNodes) {
            if (nodes == kMaxNodes + 1) Add(path, "too many nodes (max 60)");
            return;
        }
        if (depth > kMaxDepth) {
            Add(path, "nested too deep (max 8)");
            return;
        }
        if (!cJSON_IsObject(node)) {
            Add(path, "must be an object");
            return;
        }
        const cJSON* type_item = cJSON_GetObjectItemCaseSensitive(node, "type");
        if (!cJSON_IsString(type_item)) {
            Add(path + ".type", "required");
            return;
        }
        std::string type = type_item->valuestring;
        Style(node, path);
        OnTap(node, path);
        const cJSON* children = cJSON_GetObjectItemCaseSensitive(node, "children");
        bool container = type == "vstack" || type == "hstack" || type == "zstack";
        if (container) {
            if (!cJSON_IsArray(children)) {
                Add(path + ".children", "required (array)");
                return;
            }
            int i = 0;
            const cJSON* child;
            cJSON_ArrayForEach(child, children) {
                Node(child, path + ".children[" + std::to_string(i++) + "]", depth + 1);
            }
            return;
        }
        if (children) Add(path + ".children", type + " cannot have children");
        if (type == "spacer" || type == "divider" || type == "dot") return;
        if (type == "text") return Value(node, "value", path, true);
        if (type == "titleSubtitle") {
            Value(node, "title", path, true);
            return Value(node, "subtitle", path, false);
        }
        if (type == "stat") {
            Value(node, "value", path, true);
            return Value(node, "label", path, false);
        }
        if (type == "badge") return Value(node, "text", path, true);
        if (type == "progress") return Value(node, "value", path, true);
        if (type == "gauge") {
            Value(node, "value", path, true);
            Value(node, "min", path, false);
            return Value(node, "max", path, false);
        }
        if (type == "timer") return Value(node, "to", path, true);
        if (type == "clock") {
            const cJSON* format = cJSON_GetObjectItemCaseSensitive(node, "format");
            if (format && !(cJSON_IsString(format) && strlen(format->valuestring) <= 32)) {
                Add(path + ".format", "must be a strftime string of at most 32 chars");
            }
            return;
        }
        if (type == "symbol") {
            const cJSON* name = cJSON_GetObjectItemCaseSensitive(node, "name");
            if (cJSON_IsString(name)) {
                if (!SymbolGlyph(name->valuestring)) {
                    std::string near;
                    for (auto& n : NearSymbols(name->valuestring)) near += (near.empty() ? "" : ", ") + n;
                    Add(path + ".name", std::string("unknown symbol \"") + name->valuestring + "\" (did you mean " + near + "?)");
                }
            } else if (!IsBinding(name)) {
                Add(path + ".name", "required");
            }
            return;
        }
        if (type == "image") {
            const cJSON* src = cJSON_GetObjectItemCaseSensitive(node, "source");
            if (cJSON_IsString(src)) {
                std::string s = src->valuestring;
                bool ok = s.rfind("https://", 0) == 0 || s.rfind("data:image/png;base64,", 0) == 0 ||
                          s.rfind("data:image/jpeg;base64,", 0) == 0;
                if (!ok) Add(path + ".source", "must be an https URL or a data:image/png|jpeg;base64 URI");
                if (s.size() > 140000) Add(path + ".source", "image too large (max 100 KB)");
            } else if (!IsBinding(src)) {
                Add(path + ".source", "required");
            }
            return;
        }
        if (type == "chart") {
            const cJSON* kind = cJSON_GetObjectItemCaseSensitive(node, "kind");
            if (kind && !(cJSON_IsString(kind) && (!strcmp(kind->valuestring, "line") || !strcmp(kind->valuestring, "bar")))) {
                Add(path + ".kind", "must be line or bar");
            }
            const cJSON* points = cJSON_GetObjectItemCaseSensitive(node, "points");
            if (cJSON_IsArray(points)) {
                if (cJSON_GetArraySize(points) > kMaxChartPoints) Add(path + ".points", "at most 200 points");
                const cJSON* p;
                cJSON_ArrayForEach(p, points) {
                    if (!cJSON_IsNumber(p)) {
                        Add(path + ".points", "must be numbers");
                        break;
                    }
                }
            } else if (!IsBinding(points)) {
                Add(path + ".points", "required (array of numbers or binding)");
            }
            return;
        }
        Add(path + ".type", "unknown type \"" + type + "\"");
    }
};

}  // namespace

std::vector<std::string> ValidatePage(const cJSON* page) {
    PageCheck check;
    if (!cJSON_IsObject(page)) return {"page: must be an object"};
    const cJSON* id = cJSON_GetObjectItemCaseSensitive(page, "id");
    if (id && !(cJSON_IsString(id) && ValidPageId(id->valuestring))) {
        check.Add("id", "must be 1-20 chars of a-z 0-9 _ -");
    }
    const cJSON* title = cJSON_GetObjectItemCaseSensitive(page, "title");
    if (title && !(cJSON_IsString(title) && strlen(title->valuestring) <= 40)) {
        check.Add("title", "must be a string of at most 40 chars");
    }
    const cJSON* data = cJSON_GetObjectItemCaseSensitive(page, "data");
    if (data && !cJSON_IsObject(data)) check.Add("data", "must be an object");
    const cJSON* root = cJSON_GetObjectItemCaseSensitive(page, "root");
    if (!root) {
        check.Add("root", "required");
    } else {
        check.Node(root, "root", 1);
    }
    return check.errors;
}

int ClampEndPauseMs(int ms) { return std::max(kEndPauseMinMs, std::min(kEndPauseMaxMs, ms)); }

EndTimings EndTimingsFor(int end_pause_ms) {
    const int64_t pause = ClampEndPauseMs(end_pause_ms);
    return EndTimings{pause, pause + 50, std::max<int64_t>(1500, pause + 900)};
}

}  // namespace jarvis::logic
