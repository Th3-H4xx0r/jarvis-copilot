// Page JSON → LVGL objects. Input is already validated (logic::ValidatePage).
#include <cJSON.h>
#include <esp_heap_caps.h>
#include <mbedtls/base64.h>

#include "jpg/jpeg_to_image.h"
#include <wifi_manager.h>

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <ctime>

#include "board.h"
#include "jarvis/logic/jarvis_logic.h"
#include "jarvis/ui/jarvis_ui.h"

namespace jarvis::render {

lv_color_t Color(const std::string& token, const store::Theme& theme) {
    uint32_t rgb;
    if (logic::ParseHexColor(token, rgb)) return lv_color_hex(rgb);
    if (token == "accent") return lv_color_hex(theme.accent);
    if (token == "success") return lv_color_hex(theme.success);
    if (token == "warning") return lv_color_hex(theme.warning);
    if (token == "danger") return lv_color_hex(theme.danger);
    if (token == "muted") return lv_color_hex(0x8A8F98);
    if (token == "bg") return lv_color_hex(0x000000);
    return lv_color_hex(0xFFFFFF);
}

const lv_font_t* Font(int size) {
    if (size >= 48) return &lv_font_montserrat_48;
    if (size >= 40) return &lv_font_montserrat_40;
    if (size >= 32) return &lv_font_montserrat_32;
    if (size >= 28) return &lv_font_montserrat_28;
    if (size >= 24) return &lv_font_montserrat_24;
    if (size >= 20) return &lv_font_montserrat_20;
    if (size >= 16) return &lv_font_montserrat_16;
    return &lv_font_montserrat_14;
}

static const char* Glyph(const std::string& name) {
    struct Entry {
        const char* name;
        const char* glyph;
    };
    static const Entry kMap[] = {
#define SYM(n, lv) {n, LV_SYMBOL_##lv},
#include "jarvis/logic/symbols.def"
#undef SYM
    };
    for (auto& e : kMap) {
        if (name == e.name) return e.glyph;
    }
    return LV_SYMBOL_DUMMY;
}

static const cJSON* Style(const cJSON* node, const char* key) {
    return cJSON_GetObjectItemCaseSensitive(cJSON_GetObjectItemCaseSensitive(node, "style"), key);
}

static int StyleInt(const cJSON* node, const char* key, int fallback) {
    const cJSON* v = Style(node, key);
    return cJSON_IsNumber(v) ? v->valueint : fallback;
}

static std::string StyleStr(const cJSON* node, const char* key, const char* fallback) {
    const cJSON* v = Style(node, key);
    return cJSON_IsString(v) ? v->valuestring : fallback;
}

std::string ClockText(bool clock_24h, const char* format) {
    time_t now = time(nullptr);
    struct tm tm_now;
    localtime_r(&now, &tm_now);
    if (tm_now.tm_year + 1900 < 2024) return "--:--";
    char buf[48];
    const char* fmt = (format && *format) ? format : (clock_24h ? "%H:%M" : "%I:%M");
    size_t n = strftime(buf, sizeof(buf), fmt, &tm_now);
    std::string s(buf, n);  // 0 on overflow: the buffer contents are unspecified then
    if (!clock_24h && (!format || !*format) && s.size() > 1 && s[0] == '0') s.erase(0, 1);
    return s;
}

static std::string BuiltinValue(const std::string& key, bool& is_builtin, bool clock_24h) {
    is_builtin = true;
    if (key == "time") return ClockText(clock_24h, nullptr);
    if (key == "date") return ClockText(false, "%b %d");
    if (key == "weekday") return ClockText(false, "%A");
    if (key == "battery") {
        int level = 0;
        bool charging = false, discharging = false;
        if (Board::GetInstance().GetBatteryLevel(level, charging, discharging)) return std::to_string(level) + "%";
        return "";
    }
    if (key == "wifi") return WifiManager::GetInstance().GetSsid();
    is_builtin = false;
    return "";
}

static std::string Scalar(const cJSON* v) {
    if (cJSON_IsString(v)) return v->valuestring;
    if (cJSON_IsNumber(v)) {
        char buf[32];
        snprintf(buf, sizeof(buf), "%g", v->valuedouble);
        return buf;
    }
    return "";
}

// A prop's text, resolving {"$": key}. `live` is set when it must refresh every second.
static std::string Resolve(const cJSON* node, const char* prop, const Ctx& ctx, bool* live = nullptr) {
    const cJSON* v = cJSON_GetObjectItemCaseSensitive(node, prop);
    const cJSON* key = cJSON_GetObjectItemCaseSensitive(v, "$");
    if (!cJSON_IsString(key)) return Scalar(v);
    const cJSON* bound = cJSON_GetObjectItemCaseSensitive(ctx.data, key->valuestring);
    if (bound) return Scalar(bound);
    bool builtin = false;
    std::string s = BuiltinValue(key->valuestring, builtin, ctx.clock_24h);
    if (builtin && live) *live = true;
    return s;
}

static double ResolveNumber(const cJSON* node, const char* prop, const Ctx& ctx, double fallback) {
    std::string s = Resolve(node, prop, ctx);
    if (s.empty()) return fallback;
    return atof(s.c_str());
}

static lv_obj_t* Box(lv_obj_t* parent) {
    lv_obj_t* o = lv_obj_create(parent);
    lv_obj_remove_style_all(o);
    lv_obj_set_size(o, LV_SIZE_CONTENT, LV_SIZE_CONTENT);
    lv_obj_remove_flag(o, LV_OBJ_FLAG_SCROLLABLE);
    return o;
}

static lv_obj_t* Label(lv_obj_t* parent, const std::string& text, int size, lv_color_t color) {
    lv_obj_t* l = lv_label_create(parent);
    lv_label_set_text(l, text.c_str());
    lv_obj_set_style_text_font(l, Font(size), 0);
    lv_obj_set_style_text_color(l, color, 0);
    lv_obj_set_style_text_align(l, LV_TEXT_ALIGN_CENTER, 0);
    return l;
}

static lv_flex_align_t Cross(const std::string& align) {
    if (align == "left" || align == "start") return LV_FLEX_ALIGN_START;
    if (align == "right" || align == "end") return LV_FLEX_ALIGN_END;
    return LV_FLEX_ALIGN_CENTER;
}

static std::string TimerText(const cJSON* node, const Ctx& ctx) {
    double to = ResolveNumber(node, "to", ctx, 0);
    long long left = static_cast<long long>(to) - static_cast<long long>(time(nullptr));
    if (left < 0) left = 0;
    const cJSON* format = cJSON_GetObjectItemCaseSensitive(node, "format");
    char buf[32];
    if (cJSON_IsString(format) && !strcmp(format->valuestring, "relative")) {
        if (left >= 86400) snprintf(buf, sizeof(buf), "%lldd %lldh", left / 86400, (left % 86400) / 3600);
        else if (left >= 3600) snprintf(buf, sizeof(buf), "%lldh %lldm", left / 3600, (left % 3600) / 60);
        else snprintf(buf, sizeof(buf), "%lldm", (left + 59) / 60);
    } else {
        snprintf(buf, sizeof(buf), "%02lld:%02lld:%02lld", left / 3600, (left % 3600) / 60, left % 60);
    }
    return buf;
}

static lv_obj_t* Image(lv_obj_t* parent, const cJSON* node, Ctx& ctx) {
    std::string src = Resolve(node, "source", ctx);
    std::string bytes;
    size_t comma = src.find(',');
    if (src.rfind("data:image/", 0) == 0 && comma != std::string::npos) {
        std::string b64 = src.substr(comma + 1);
        size_t out_len = 0;
        bytes.resize(b64.size() * 3 / 4 + 4);
        if (mbedtls_base64_decode(reinterpret_cast<unsigned char*>(&bytes[0]), bytes.size(), &out_len,
                                  reinterpret_cast<const unsigned char*>(b64.data()), b64.size()) == 0) {
            bytes.resize(out_len);
        } else {
            bytes.clear();
        }
    } else if (ctx.images) {
        auto it = ctx.images->find(src);
        if (it != ctx.images->end()) bytes = it->second;
    }
    int w = StyleInt(node, "width", 96), h = StyleInt(node, "height", 96);
    if (bytes.empty()) {  // not fetched / bad data: a quiet placeholder rather than nothing
        lv_obj_t* ph = Label(parent, LV_SYMBOL_IMAGE, 24, lv_color_hex(0x8A8F98));
        return ph;
    }
    lv_image_dsc_t dsc = {};
    dsc.header.magic = LV_IMAGE_HEADER_MAGIC;
    const auto* magic = reinterpret_cast<const uint8_t*>(bytes.data());
    if (bytes.size() > 3 && magic[0] == 0xFF && magic[1] == 0xD8) {
        // Photos: decode the JPEG to RGB565 (in PSRAM) and let LVGL fit it to the box.
        uint8_t* pixels = nullptr;
        size_t len = 0, pw = 0, ph = 0, stride = 0;
        if (jpeg_to_image(magic, bytes.size(), &pixels, &len, &pw, &ph, &stride) != ESP_OK || !pixels) {
            return Label(parent, LV_SYMBOL_IMAGE, 24, lv_color_hex(0x8A8F98));
        }
        ctx.image_bytes.emplace_back(reinterpret_cast<const char*>(pixels), len);
        heap_caps_free(pixels);
        dsc.header.cf = LV_COLOR_FORMAT_RGB565;
        dsc.header.w = pw;
        dsc.header.h = ph;
        dsc.header.stride = stride;
    } else {
        ctx.image_bytes.push_back(std::move(bytes));  // PNG: LVGL's own decoder reads the file bytes
        dsc.header.cf = LV_COLOR_FORMAT_RAW;
    }
    dsc.data_size = ctx.image_bytes.back().size();
    dsc.data = reinterpret_cast<const uint8_t*>(ctx.image_bytes.back().data());
    ctx.image_dscs.push_back(dsc);
    lv_obj_t* img = lv_image_create(parent);
    lv_image_set_src(img, &ctx.image_dscs.back());
    lv_obj_set_size(img, w, h);
    lv_image_set_inner_align(img, LV_IMAGE_ALIGN_CONTAIN);
    return img;
}

lv_obj_t* Build(lv_obj_t* parent, const cJSON* node, Ctx& ctx) {
    std::string type = cJSON_GetObjectItemCaseSensitive(node, "type")->valuestring;
    std::string color_token = StyleStr(node, "color", "text");
    lv_color_t color = Color(color_token, ctx.theme);
    int size = StyleInt(node, "size", 16);
    lv_obj_t* obj = nullptr;

    if (type == "vstack" || type == "hstack" || type == "zstack") {
        obj = Box(parent);
        if (type != "zstack") {
            lv_obj_set_flex_flow(obj, type == "vstack" ? LV_FLEX_FLOW_COLUMN : LV_FLEX_FLOW_ROW);
            lv_flex_align_t cross = Cross(StyleStr(node, "align", "center"));
            lv_obj_set_flex_align(obj, LV_FLEX_ALIGN_CENTER, cross, cross);
            int gap = StyleInt(node, "gap", 4);
            lv_obj_set_style_pad_row(obj, gap, 0);
            lv_obj_set_style_pad_column(obj, gap, 0);
        }
        const cJSON* child;
        cJSON_ArrayForEach(child, cJSON_GetObjectItemCaseSensitive(node, "children")) {
            lv_obj_t* c = Build(obj, child, ctx);
            if (type == "zstack" && c) lv_obj_align(c, LV_ALIGN_CENTER, 0, 0);
        }
        if (type == "zstack") lv_obj_set_size(obj, StyleInt(node, "width", 200), StyleInt(node, "height", 120));
    } else if (type == "spacer") {
        obj = Box(parent);
        lv_obj_set_size(obj, 1, StyleInt(node, "size", 8));
        lv_obj_set_flex_grow(obj, 1);
    } else if (type == "text") {
        bool live = false;
        obj = Label(parent, Resolve(node, "value", ctx, &live), size, color);
        lv_obj_set_style_max_width(obj, 200, 0);
        lv_label_set_long_mode(obj, LV_LABEL_LONG_WRAP);
        std::string align = StyleStr(node, "align", "center");
        lv_obj_set_style_text_align(obj, align == "left" ? LV_TEXT_ALIGN_LEFT : align == "right" ? LV_TEXT_ALIGN_RIGHT : LV_TEXT_ALIGN_CENTER, 0);
        if (live) ctx.live.push_back({obj, node, "value"});
    } else if (type == "titleSubtitle" || type == "stat") {
        obj = Box(parent);
        lv_obj_set_flex_flow(obj, LV_FLEX_FLOW_COLUMN);
        lv_obj_set_flex_align(obj, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
        bool stat = type == "stat";
        bool live = false;
        lv_obj_t* top = Label(obj, Resolve(node, stat ? "value" : "title", ctx, &live), stat ? 32 : 20, color);
        if (live) ctx.live.push_back({top, node, stat ? "value" : "title"});
        std::string sub = Resolve(node, stat ? "label" : "subtitle", ctx);
        if (!sub.empty()) Label(obj, sub, 14, Color("muted", ctx.theme));
    } else if (type == "symbol") {
        obj = Label(parent, Glyph(Resolve(node, "name", ctx)), size, color);
    } else if (type == "image") {
        obj = Image(parent, node, ctx);
    } else if (type == "badge") {
        obj = Label(parent, Resolve(node, "text", ctx), 14, lv_color_hex(0x000000));
        lv_obj_set_style_bg_color(obj, color_token == "text" ? Color("accent", ctx.theme) : color, 0);
        lv_obj_set_style_bg_opa(obj, LV_OPA_COVER, 0);
        lv_obj_set_style_radius(obj, 10, 0);
        lv_obj_set_style_pad_hor(obj, 8, 0);
        lv_obj_set_style_pad_ver(obj, 3, 0);
    } else if (type == "progress") {
        obj = lv_bar_create(parent);
        lv_obj_set_size(obj, StyleInt(node, "width", 160), 8);
        lv_bar_set_range(obj, 0, 1000);
        lv_bar_set_value(obj, static_cast<int32_t>(ResolveNumber(node, "value", ctx, 0) * 1000), LV_ANIM_OFF);
        lv_obj_set_style_bg_color(obj, lv_color_hex(0x2A2D33), LV_PART_MAIN);
        lv_obj_set_style_bg_color(obj, color_token == "text" ? Color("accent", ctx.theme) : color, LV_PART_INDICATOR);
    } else if (type == "gauge") {
        obj = lv_arc_create(parent);
        int d = StyleInt(node, "size", 120);
        d = d < 40 ? 120 : d;
        lv_obj_set_size(obj, d, d);
        lv_arc_set_rotation(obj, 135);
        lv_arc_set_bg_angles(obj, 0, 270);
        double lo = ResolveNumber(node, "min", ctx, 0), hi = ResolveNumber(node, "max", ctx, 100);
        lv_arc_set_range(obj, static_cast<int32_t>(lo), static_cast<int32_t>(hi > lo ? hi : lo + 1));
        lv_arc_set_value(obj, static_cast<int32_t>(ResolveNumber(node, "value", ctx, 0)));
        lv_obj_remove_style(obj, nullptr, LV_PART_KNOB);
        lv_obj_remove_flag(obj, LV_OBJ_FLAG_CLICKABLE);
        int thickness = StyleInt(node, "thickness", 10);
        lv_obj_set_style_arc_width(obj, thickness, LV_PART_MAIN);
        lv_obj_set_style_arc_width(obj, thickness, LV_PART_INDICATOR);
        lv_obj_set_style_arc_color(obj, lv_color_hex(0x2A2D33), LV_PART_MAIN);
        lv_obj_set_style_arc_color(obj, color_token == "text" ? Color("accent", ctx.theme) : color, LV_PART_INDICATOR);
    } else if (type == "chart") {
        obj = Box(parent);
        lv_obj_set_flex_flow(obj, LV_FLEX_FLOW_COLUMN);
        lv_obj_set_flex_align(obj, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
        const cJSON* points = cJSON_GetObjectItemCaseSensitive(node, "points");
        const cJSON* key = cJSON_GetObjectItemCaseSensitive(points, "$");
        if (cJSON_IsString(key)) points = cJSON_GetObjectItemCaseSensitive(ctx.data, key->valuestring);
        std::vector<int32_t> values;
        double lo = 1e18, hi = -1e18;
        const cJSON* p;
        cJSON_ArrayForEach(p, points) {
            if (!cJSON_IsNumber(p) || values.size() >= logic::kMaxChartPoints) continue;
            values.push_back(static_cast<int32_t>(p->valuedouble * 100));
            lo = std::min(lo, p->valuedouble);
            hi = std::max(hi, p->valuedouble);
        }
        const cJSON* mn = cJSON_GetObjectItemCaseSensitive(node, "min");
        const cJSON* mx = cJSON_GetObjectItemCaseSensitive(node, "max");
        if (cJSON_IsNumber(mn)) lo = mn->valuedouble;
        if (cJSON_IsNumber(mx)) hi = mx->valuedouble;
        if (values.empty()) lo = 0, hi = 1;
        if (hi <= lo) hi = lo + 1;
        lv_obj_t* chart = lv_chart_create(obj);
        lv_obj_set_size(chart, StyleInt(node, "width", 180), StyleInt(node, "height", 80));
        const cJSON* kind = cJSON_GetObjectItemCaseSensitive(node, "kind");
        lv_chart_set_type(chart, cJSON_IsString(kind) && !strcmp(kind->valuestring, "bar") ? LV_CHART_TYPE_BAR : LV_CHART_TYPE_LINE);
        lv_chart_set_div_line_count(chart, 0, 0);
        lv_obj_set_style_bg_opa(chart, LV_OPA_TRANSP, 0);
        lv_obj_set_style_border_width(chart, 0, 0);
        lv_obj_set_style_pad_all(chart, 0, 0);
        lv_obj_set_style_size(chart, 0, 0, LV_PART_INDICATOR);
        lv_chart_set_axis_range(chart, LV_CHART_AXIS_PRIMARY_Y, static_cast<int32_t>(lo * 100), static_cast<int32_t>(hi * 100));
        lv_chart_set_point_count(chart, values.empty() ? 1 : values.size());
        lv_chart_series_t* series = lv_chart_add_series(chart, color_token == "text" ? Color("accent", ctx.theme) : color, LV_CHART_AXIS_PRIMARY_Y);
        for (size_t i = 0; i < values.size(); ++i) lv_chart_set_value_by_id(chart, series, i, values[i]);
        lv_chart_refresh(chart);
        const cJSON* labels = cJSON_GetObjectItemCaseSensitive(node, "labels");
        if (cJSON_IsObject(labels)) {
            lv_obj_t* row = Box(obj);
            lv_obj_set_width(row, StyleInt(node, "width", 180));
            lv_obj_set_flex_flow(row, LV_FLEX_FLOW_ROW);
            lv_obj_set_flex_align(row, LV_FLEX_ALIGN_SPACE_BETWEEN, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
            Label(row, Scalar(cJSON_GetObjectItemCaseSensitive(labels, "first")), 14, Color("muted", ctx.theme));
            Label(row, Scalar(cJSON_GetObjectItemCaseSensitive(labels, "last")), 14, Color("muted", ctx.theme));
        }
    } else if (type == "timer") {
        obj = Label(parent, TimerText(node, ctx), size, color);
        ctx.live.push_back({obj, node, "timer"});
    } else if (type == "clock") {
        const cJSON* format = cJSON_GetObjectItemCaseSensitive(node, "format");
        obj = Label(parent, ClockText(ctx.clock_24h, cJSON_IsString(format) ? format->valuestring : nullptr), size, color);
        ctx.live.push_back({obj, node, "clock"});
    } else if (type == "divider") {
        obj = Box(parent);
        lv_obj_set_size(obj, StyleInt(node, "width", 160), 1);
        lv_obj_set_style_bg_color(obj, color_token == "text" ? Color("muted", ctx.theme) : color, 0);
        lv_obj_set_style_bg_opa(obj, LV_OPA_COVER, 0);
    } else if (type == "dot") {
        obj = Box(parent);
        int d = StyleInt(node, "size", 8);
        lv_obj_set_size(obj, d, d);
        lv_obj_set_style_radius(obj, LV_RADIUS_CIRCLE, 0);
        lv_obj_set_style_bg_color(obj, color_token == "text" ? Color("accent", ctx.theme) : color, 0);
        lv_obj_set_style_bg_opa(obj, LV_OPA_COVER, 0);
    }

    const cJSON* tap = cJSON_GetObjectItemCaseSensitive(node, "onTap");
    if (obj && cJSON_IsObject(tap)) {
        const cJSON* action = cJSON_GetObjectItemCaseSensitive(tap, "action");
        const cJSON* text = cJSON_GetObjectItemCaseSensitive(tap, "text");
        ctx.taps.push_back({obj, cJSON_IsString(action) ? action->valuestring : "",
                            cJSON_IsString(text) ? text->valuestring : ""});
    }
    return obj;
}

void Refresh(Ctx& ctx) {
    for (auto& l : ctx.live) {
        std::string text;
        if (!strcmp(l.prop, "timer")) {
            text = TimerText(l.node, ctx);
        } else if (!strcmp(l.prop, "clock")) {
            const cJSON* format = cJSON_GetObjectItemCaseSensitive(l.node, "format");
            text = ClockText(ctx.clock_24h, cJSON_IsString(format) ? format->valuestring : nullptr);
        } else {
            text = Resolve(l.node, l.prop, ctx);
        }
        if (strcmp(lv_label_get_text(l.label), text.c_str())) lv_label_set_text(l.label, text.c_str());
    }
}

}  // namespace jarvis::render
