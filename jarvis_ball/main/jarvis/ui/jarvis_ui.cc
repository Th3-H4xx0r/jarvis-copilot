#include "jarvis_ui.h"

#include <cJSON.h>
#include <esp_app_desc.h>
#include <esp_heap_caps.h>
#include <esp_log.h>
#include <esp_partition.h>
#include <wifi_manager.h>

#include <cmath>
#include <cstring>

#include <algorithm>

#include "audio_codec.h"
#include "board.h"
#include "display.h"
#include "jarvis/board_caps.h"
#include "jarvis/logic/jarvis_logic.h"

#define TAG "JarvisUi"

namespace jarvis {

namespace {

constexpr int kScreen = 240;
// Orb animation paused while the ball's responsiveness is sorted out: one still frame,
// no frame timer, no pulses. Flip to true to bring the motion back.
constexpr bool kAnimateOrb = false;
const lv_color_t kBlack = lv_color_hex(0x000000);
const lv_color_t kWhite = lv_color_hex(0xFFFFFF);
const lv_color_t kMuted = lv_color_hex(0x8A8F98);

enum class Screen { System, Setup, Home, Shown };

struct MenuRow {
    std::string label;
    std::function<void()> action;
    lv_obj_t* obj = nullptr;
};

void SizeAnim(void* var, int32_t v) {
    auto* o = static_cast<lv_obj_t*>(var);
    lv_obj_set_size(o, v, v);
    lv_obj_center(o);
}

void OpaAnim(void* var, int32_t v) { lv_obj_set_style_bg_opa(static_cast<lv_obj_t*>(var), static_cast<lv_opa_t>(v), 0); }

void Pulse(lv_obj_t* obj, lv_anim_exec_xcb_t cb, int32_t from, int32_t to, uint32_t ms, int32_t repeat = LV_ANIM_REPEAT_INFINITE) {
    lv_anim_t a;
    lv_anim_init(&a);
    lv_anim_set_var(&a, obj);
    lv_anim_set_exec_cb(&a, cb);
    lv_anim_set_values(&a, from, to);
    lv_anim_set_duration(&a, ms);
    lv_anim_set_reverse_duration(&a, ms);
    lv_anim_set_repeat_count(&a, repeat);
    lv_anim_set_path_cb(&a, lv_anim_path_ease_in_out);
    lv_anim_start(&a);
}

lv_obj_t* Circle(lv_obj_t* parent, int d) {
    lv_obj_t* o = lv_obj_create(parent);
    lv_obj_remove_style_all(o);
    lv_obj_set_size(o, d, d);
    lv_obj_set_style_radius(o, LV_RADIUS_CIRCLE, 0);
    lv_obj_set_style_bg_opa(o, LV_OPA_COVER, 0);
    lv_obj_remove_flag(o, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_center(o);
    return o;
}

lv_obj_t* GlassButton(lv_obj_t* parent, const char* glyph, int x, int y) {
    lv_obj_t* b = lv_obj_create(parent);
    lv_obj_remove_style_all(b);
    lv_obj_set_size(b, 36, 36);
    lv_obj_set_pos(b, x, y);
    lv_obj_set_style_radius(b, LV_RADIUS_CIRCLE, 0);
    lv_obj_set_style_bg_color(b, kWhite, 0);
    lv_obj_set_style_bg_opa(b, 40, 0);
    lv_obj_set_style_border_color(b, kWhite, 0);
    lv_obj_set_style_border_opa(b, 90, 0);
    lv_obj_set_style_border_width(b, 1, 0);
    lv_obj_remove_flag(b, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_t* l = lv_label_create(b);
    lv_label_set_text(l, glyph);
    lv_obj_set_style_text_color(l, kWhite, 0);
    lv_obj_set_style_text_font(l, &lv_font_montserrat_16, 0);
    lv_obj_center(l);
    return b;
}

bool Hit(lv_obj_t* obj, int x, int y) {
    if (!obj || lv_obj_has_flag(obj, LV_OBJ_FLAG_HIDDEN)) return false;
    for (lv_obj_t* p = lv_obj_get_parent(obj); p; p = lv_obj_get_parent(p)) {
        if (lv_obj_has_flag(p, LV_OBJ_FLAG_HIDDEN)) return false;
    }
    lv_area_t a;
    lv_obj_get_coords(obj, &a);
    const int slop = 6;  // fingers are bigger than pixels
    return x >= a.x1 - slop && x <= a.x2 + slop && y >= a.y1 - slop && y <= a.y2 + slop;
}

lv_obj_t* Layer(lv_obj_t* parent, bool opaque) {
    lv_obj_t* o = lv_obj_create(parent);
    lv_obj_remove_style_all(o);
    lv_obj_set_size(o, kScreen, kScreen);
    lv_obj_set_pos(o, 0, 0);
    lv_obj_remove_flag(o, LV_OBJ_FLAG_SCROLLABLE);
    if (opaque) {
        lv_obj_set_style_bg_color(o, kBlack, 0);
        lv_obj_set_style_bg_opa(o, LV_OPA_COVER, 0);
    }
    return o;
}

}  // namespace

struct Ui::Impl {
    Display* display = nullptr;
    lv_obj_t* root = nullptr;
    lv_obj_t* page_layer = nullptr;
    lv_obj_t* orb_layer = nullptr;
    lv_obj_t* orb_box = nullptr;
    lv_obj_t* glow = nullptr;
    lv_obj_t* mid = nullptr;
    lv_obj_t* core = nullptr;
    // The phone's orb, pre-rendered (scripts/render_orb.sh) and memory-mapped from flash.
    lv_obj_t* orb_img = nullptr;
    lv_timer_t* orb_timer = nullptr;
    std::vector<lv_image_dsc_t> orb_frames;
    int orb_frame = 0;
    lv_obj_t* caption = nullptr;
    // Reply layout morph: 0 = the big orb in the centre, 1000 = the small orb at the bottom.
    // The same orb frame, box-filtered to each size, so it shrinks instead of swapping.
    int orb_morph = 0;
    int orb_morph_target = 0;
    uint16_t* orb_scaled_px = nullptr;
    lv_image_dsc_t orb_scaled = {};
    lv_obj_t* status_pill = nullptr;   // "● Listening" above the orb, like the phone
    lv_obj_t* ring = nullptr;          // screen-edge ring in the voice state's colour (an arc)
    int ring_fill = 0;                 // 0..1000: grows up both sides from the bottom
    int ring_target = 0;
    int ring_width = kRingWidth;       // pulses with the voice while listening
    lv_timer_t* spin_timer = nullptr;  // thinking: a Material-style indeterminate spinner
    uint32_t spin_start = 0;
    int spin_cycle = -1;
    lv_obj_t* close_btn = nullptr;     // stands in for the menu button while the menu is open
    lv_obj_t* status_label = nullptr;
    lv_obj_t* menu_btn = nullptr;
    lv_obj_t* back_btn = nullptr;
    lv_obj_t* menu_layer = nullptr;
    lv_obj_t* setup_message = nullptr;
    lv_obj_t* clock_time = nullptr;
    lv_obj_t* clock_date = nullptr;
    lv_obj_t* clock_arc = nullptr;
    lv_timer_t* tick = nullptr;
    lv_timer_t* error_timer = nullptr;

    Screen screen = Screen::System;
    store::UiSettings settings;
    cJSON* page_doc = nullptr;  // the rendered custom home or shown page
    std::string shown_id;
    render::Ctx ctx;
    std::map<std::string, std::string> images;
    std::vector<MenuRow> rows;
    bool menu_open = false;
    bool settings_menu = false;
    int highlight = 0;
    OrbState orb_state = OrbState::Idle;
    bool voice_active = false;
    Ui* owner = nullptr;

    // ---- pages --------------------------------------------------------------
    void ClearPage() {
        lv_obj_clean(page_layer);
        ctx.taps.clear();
        ctx.live.clear();
        ctx.image_dscs.clear();
        ctx.image_bytes.clear();
        clock_time = clock_date = clock_arc = nullptr;
        if (page_doc) cJSON_Delete(page_doc);
        page_doc = nullptr;
    }

    lv_obj_t* Column(lv_obj_t* parent) {
        lv_obj_t* col = lv_obj_create(parent);
        lv_obj_remove_style_all(col);
        lv_obj_set_size(col, 200, 200);
        lv_obj_center(col);
        lv_obj_set_flex_flow(col, LV_FLEX_FLOW_COLUMN);
        lv_obj_set_flex_align(col, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
        lv_obj_set_style_pad_row(col, 6, 0);
        lv_obj_remove_flag(col, LV_OBJ_FLAG_SCROLLABLE);
        return col;
    }

    lv_obj_t* Text(lv_obj_t* parent, const std::string& text, const lv_font_t* font, lv_color_t color) {
        lv_obj_t* l = lv_label_create(parent);
        lv_label_set_text(l, text.c_str());
        lv_obj_set_style_text_font(l, font, 0);
        lv_obj_set_style_text_color(l, color, 0);
        lv_obj_set_style_text_align(l, LV_TEXT_ALIGN_CENTER, 0);
        lv_label_set_long_mode(l, LV_LABEL_LONG_WRAP);
        lv_obj_set_style_max_width(l, 190, 0);
        return l;
    }

    bool RenderDoc(const std::string& json) {
        cJSON* doc = cJSON_Parse(json.c_str());
        const cJSON* root_node = cJSON_GetObjectItemCaseSensitive(doc, "root");
        if (!doc || !root_node) {
            cJSON_Delete(doc);
            return false;
        }
        page_doc = doc;
        ctx.theme = settings.theme;
        ctx.clock_24h = settings.clock_24h;
        ctx.data = cJSON_GetObjectItemCaseSensitive(doc, "data");
        ctx.images = &images;
        lv_obj_t* col = Column(page_layer);
        render::Build(col, root_node, ctx);
        return true;
    }

    void BuildClock() {
        clock_arc = lv_arc_create(page_layer);
        lv_obj_set_size(clock_arc, 226, 226);
        lv_obj_center(clock_arc);
        lv_arc_set_rotation(clock_arc, 270);
        lv_arc_set_bg_angles(clock_arc, 0, 360);
        lv_arc_set_range(clock_arc, 0, 100);
        lv_obj_remove_style(clock_arc, nullptr, LV_PART_KNOB);
        lv_obj_remove_flag(clock_arc, LV_OBJ_FLAG_CLICKABLE);
        lv_obj_set_style_arc_width(clock_arc, 3, LV_PART_MAIN);
        lv_obj_set_style_arc_width(clock_arc, 3, LV_PART_INDICATOR);
        lv_obj_set_style_arc_color(clock_arc, lv_color_hex(0x1C1E22), LV_PART_MAIN);
        lv_obj_set_style_arc_color(clock_arc, lv_color_hex(settings.theme.accent), LV_PART_INDICATOR);
        lv_obj_t* col = Column(page_layer);
        clock_time = Text(col, "--:--", &lv_font_montserrat_48, kWhite);
        clock_date = Text(col, "", &lv_font_montserrat_16, kMuted);
        UpdateClock();
    }

    void UpdateClock() {
        if (!clock_time) return;
        lv_label_set_text(clock_time, render::ClockText(settings.clock_24h, nullptr).c_str());
        std::string date = render::ClockText(false, "%A, %b %d");
        lv_label_set_text(clock_date, date.rfind("--", 0) == 0 ? "" : date.c_str());
        int level = 0;
        bool charging = false, discharging = false;
        if (Board::GetInstance().GetBatteryLevel(level, charging, discharging)) lv_arc_set_value(clock_arc, level);
    }

    void ShowHomeLocked() {
        CloseMenu();
        ClearPage();
        shown_id.clear();
        settings = store::LoadUi();
        screen = Screen::Home;
        const std::string& home = settings.home;
        if (home == "clock") {
            BuildClock();
        } else if (home != "orb") {
            if (!RenderDoc(store::LoadHome(home))) {
                ESP_LOGW(TAG, "home %s missing; showing the orb", home.c_str());
                settings.home = "orb";
            }
        }
        UpdateChrome();
    }

    // ---- orb -----------------------------------------------------------------
    bool OrbFull() const {
        if (screen == Screen::Setup || screen == Screen::System) return false;
        if (voice_active) return screen != Screen::Shown;
        return screen == Screen::Home && settings.home == "orb";
    }

    bool OrbVisible() const { return OrbFull() || (voice_active && screen == Screen::Shown); }

    // Like the phone: while Jarvis speaks, the orb shrinks to the bottom and the words take the screen.
    bool ReplyLayout() const { return OrbFull() && voice_active && orb_state == OrbState::Speaking; }
    bool OrbBig() const { return OrbFull() && !ReplyLayout(); }

    static constexpr int kOrbNative = 160;
    static constexpr int kOrbSmall = 48;
    int BigSize() const { return kOrbNative; }
    int BigCy() const { return kScreen / 2 + (voice_active ? 0 : -8); }
    static constexpr int kOrbSmallCy = 202; // bottom, under the reply text

    // Writes the current orb frame at `size` px into orb_scaled (box filter; caches are off,
    // so re-pointing the image at the same descriptor picks up the new pixels).
    const lv_image_dsc_t* ScaledOrb(int size) {
        const lv_image_dsc_t& src = orb_frames[orb_frame];
        if (size >= kOrbNative) return &src;
        if (!orb_scaled_px) {
            orb_scaled_px = static_cast<uint16_t*>(
                heap_caps_malloc(kOrbNative * kOrbNative * 2, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT));
            if (!orb_scaled_px) return &src;
        }
        const uint8_t* in = src.data;
        for (int y = 0; y < size; ++y) {
            int y0 = y * kOrbNative / size, y1 = std::max(y0 + 1, (y + 1) * kOrbNative / size);
            for (int x = 0; x < size; ++x) {
                int x0 = x * kOrbNative / size, x1 = std::max(x0 + 1, (x + 1) * kOrbNative / size);
                uint32_t r = 0, g = 0, b = 0, n = 0;
                for (int sy = y0; sy < y1; ++sy) {
                    const uint8_t* row = in + sy * kOrbNative * 2;
                    for (int sx = x0; sx < x1; ++sx) {
                        uint16_t px = row[sx * 2] | (row[sx * 2 + 1] << 8);
                        r += px >> 11; g += (px >> 5) & 0x3F; b += px & 0x1F; ++n;
                    }
                }
                uint16_t out = static_cast<uint16_t>(((r / n) << 11) | ((g / n) << 5) | (b / n));
                orb_scaled_px[y * size + x] = out;  // little-endian RGB565, like the frames
            }
        }
        orb_scaled.header.magic = LV_IMAGE_HEADER_MAGIC;
        orb_scaled.header.cf = LV_COLOR_FORMAT_RGB565;
        orb_scaled.header.w = size;
        orb_scaled.header.h = size;
        orb_scaled.header.stride = size * 2;
        orb_scaled.data_size = size * size * 2;
        orb_scaled.data = static_cast<const uint8_t*>(static_cast<void*>(orb_scaled_px));
        return &orb_scaled;
    }

    void SetOrbMorph(int v) {
        orb_morph = v;
        int size = BigSize() - (BigSize() - kOrbSmall) * v / 1000;
        int cy = BigCy() + (kOrbSmallCy - BigCy()) * v / 1000;
        lv_obj_set_size(orb_box, size, size);
        lv_obj_align(orb_box, LV_ALIGN_TOP_LEFT, kScreen / 2 - size / 2, cy - size / 2);
        lv_image_set_src(orb_img, ScaledOrb(size));
        lv_obj_center(orb_img);
    }

    void MorphOrbTo(int target) {
        if (target == orb_morph_target && lv_anim_get(orb_box, nullptr)) return;
        if (target == orb_morph) return SetOrbMorph(target);  // settled: just re-place it
        orb_morph_target = target;
        lv_anim_delete(orb_box, nullptr);
        lv_anim_t a;
        lv_anim_init(&a);
        lv_anim_set_var(&a, orb_box);
        lv_anim_set_user_data(&a, this);
        lv_anim_set_values(&a, orb_morph, target);
        lv_anim_set_duration(&a, 60 + 420 * std::abs(target - orb_morph) / 1000);
        lv_anim_set_path_cb(&a, lv_anim_path_ease_in_out);
        lv_anim_set_custom_exec_cb(&a, [](lv_anim_t* anim, int32_t v) {
            static_cast<Impl*>(lv_anim_get_user_data(anim))->SetOrbMorph(v);
        });
        lv_anim_start(&a);
    }

    // Reply text: as big as it can be while it fits between the menu button and the orb.
    void FitCaption() {
        if (!reply_caption) return;
        const char* text = lv_label_get_text(caption);
        const lv_font_t* font = &lv_font_montserrat_16;
        for (const lv_font_t* f : {&lv_font_montserrat_24, &lv_font_montserrat_20}) {
            lv_point_t size;
            lv_text_get_size(&size, text, f, 0, 0, kReplyW, LV_TEXT_FLAG_NONE);
            if (size.y <= kReplyH) { font = f; break; }
        }
        lv_obj_set_style_text_font(caption, font, 0);
    }

    void FadeIn(lv_obj_t* obj, uint32_t delay) {
        lv_anim_delete(obj, nullptr);
        lv_obj_set_style_text_opa(obj, LV_OPA_TRANSP, 0);
        lv_anim_t a;
        lv_anim_init(&a);
        lv_anim_set_var(&a, obj);
        lv_anim_set_values(&a, LV_OPA_TRANSP, LV_OPA_COVER);
        lv_anim_set_delay(&a, delay);
        lv_anim_set_duration(&a, 220);
        lv_anim_set_exec_cb(&a, [](void* var, int32_t v) {
            lv_obj_set_style_text_opa(static_cast<lv_obj_t*>(var), v, 0);
        });
        lv_anim_start(&a);
    }

    static constexpr int kReplyW = 184;
    static constexpr int kReplyH = 92;  // y 80..172: below the menu button, above the small orb
    bool reply_caption = false;

    static constexpr int kRingWidth = 5;

    void SetRingWidth(int w) {
        if (w == ring_width) return;
        ring_width = w;
        lv_obj_set_style_arc_width(ring, w, LV_PART_MAIN);
    }

    // Thinking: the arc chases itself round like Google's loading spinner — the head
    // sweeps out, then the tail catches up, while the whole thing turns and the colour
    // steps through the theme each lap.
    void StartSpin() {
        lv_anim_delete(ring, nullptr);
        SetRingWidth(kRingWidth);
        lv_arc_set_rotation(ring, 270);  // start at the top
        spin_start = lv_tick_get();
        spin_cycle = -1;
        spin_timer = lv_timer_create([](lv_timer_t* t) { static_cast<Impl*>(lv_timer_get_user_data(t))->SpinTick(); },
                                     30, this);
        SpinTick();
    }

    void StopSpin() {
        if (!spin_timer) return;
        lv_timer_delete(spin_timer);
        spin_timer = nullptr;
        lv_arc_set_rotation(ring, 90);
    }

    void SpinTick() {
        constexpr uint32_t kLapMs = 1333;
        uint32_t ms = lv_tick_elaps(spin_start);
        int cycle = static_cast<int>(ms / kLapMs);
        float p = static_cast<float>(ms % kLapMs) / kLapMs;
        auto ease = [](float x) { return x < 0.5f ? 4 * x * x * x : 1 - std::pow(-2 * x + 2, 3) / 2; };
        float head = 270.0f * ease(std::min(p * 2, 1.0f));
        float tail = 270.0f * ease(std::max(p * 2 - 1, 0.0f));
        float base = ms * 360.0f / 1568.0f + cycle * 270.0f;
        int start = static_cast<int>(base + tail) % 360;
        int end = static_cast<int>(base + head + 14) % 360;
        if (cycle != spin_cycle) {
            spin_cycle = cycle;
            const auto& t = settings.theme;
            const uint32_t colors[] = {t.accent, t.danger, t.warning, t.success};
            lv_obj_set_style_arc_color(ring, lv_color_hex(colors[cycle % 4]), LV_PART_MAIN);
        }
        lv_arc_set_bg_angles(ring, start, end);
    }

    void SetRingFill(int v) {
        ring_fill = v;
        int a = 180 * v / 1000;  // degrees either side of the bottom (the arc is rotated 90°)
        if (a >= 180) lv_arc_set_bg_angles(ring, 0, 360);
        else if (a <= 0) lv_arc_set_bg_angles(ring, 0, 0);
        else lv_arc_set_bg_angles(ring, 360 - a, a);
    }

    // Voice on: the ring fills up both sides to meet at the top. Voice off: it drains back down.
    void UpdateRing() {
        if (voice_active && orb_state == OrbState::Thinking) {
            if (!spin_timer) StartSpin();
            ring_target = 1000;
            return;
        }
        if (spin_timer) {
            StopSpin();
            SetRingFill(1000);  // settle to a full ring; it drains from there
        }
        if (!voice_active || orb_state != OrbState::Listening) SetRingWidth(kRingWidth);
        if (voice_active) {
            const auto& t = settings.theme;
            uint32_t color = orb_state == OrbState::Thinking ? t.warning
                             : orb_state == OrbState::Speaking ? t.success
                             : orb_state == OrbState::Error ? t.danger : t.accent;
            lv_obj_set_style_arc_color(ring, lv_color_hex(color), LV_PART_MAIN);
        }
        int target = voice_active ? 1000 : 0;
        if (target == ring_target) return;
        ring_target = target;
        lv_anim_delete(ring, nullptr);
        lv_anim_t a;
        lv_anim_init(&a);
        lv_anim_set_var(&a, ring);
        lv_anim_set_user_data(&a, this);
        lv_anim_set_values(&a, ring_fill, target);
        lv_anim_set_duration(&a, 80 + 470 * std::abs(target - ring_fill) / 1000);
        lv_anim_set_path_cb(&a, voice_active ? lv_anim_path_ease_out : lv_anim_path_ease_in);
        lv_anim_set_custom_exec_cb(&a, [](lv_anim_t* anim, int32_t v) {
            static_cast<Impl*>(lv_anim_get_user_data(anim))->SetRingFill(v);
        });
        lv_anim_start(&a);
    }

    void UpdateOrbLayer() {
        UpdateRing();
        if (!OrbVisible()) {
            lv_obj_add_flag(orb_layer, LV_OBJ_FLAG_HIDDEN);
            if (orb_timer) lv_timer_pause(orb_timer);
            if (orb_img && orb_morph) { lv_anim_delete(orb_box, nullptr); orb_morph_target = 0; SetOrbMorph(0); }
            return;
        }
        if (orb_timer && kAnimateOrb) lv_timer_resume(orb_timer);
        lv_obj_remove_flag(orb_layer, LV_OBJ_FLAG_HIDDEN);
        bool full = OrbFull();
        lv_obj_set_style_bg_opa(orb_layer, full ? LV_OPA_COVER : LV_OPA_TRANSP, 0);
        bool reply = ReplyLayout();
        if (reply != reply_caption) {
            reply_caption = reply;
            lv_label_set_long_mode(caption, LV_LABEL_LONG_DOT);
            if (reply) {
                lv_obj_set_size(caption, kReplyW, kReplyH);
                lv_obj_align(caption, LV_ALIGN_TOP_MID, 0, 80);
                FitCaption();
            } else {
                lv_obj_set_style_text_font(caption, &lv_font_montserrat_16, 0);
                lv_obj_set_size(caption, 150, 20);
                lv_obj_align(caption, LV_ALIGN_TOP_MID, 0, 192);
            }
            // Let the orb get out of the way before the words appear.
            if (full && orb_img) FadeIn(caption, reply ? 240 : 300);
        }
        if (orb_img && full) {
            MorphOrbTo(reply ? 1000 : 0);
        } else if (full) {
            lv_obj_set_size(orb_box, reply ? 48 : 200, reply ? 48 : 200);
            if (reply) lv_obj_align(orb_box, LV_ALIGN_BOTTOM_MID, 0, -14);
            else lv_obj_align(orb_box, LV_ALIGN_CENTER, 0, voice_active ? 4 : -8);
        } else {
            if (orb_img && orb_morph) { lv_anim_delete(orb_box, nullptr); orb_morph_target = 0; orb_morph = 0; }
            lv_obj_set_size(orb_box, 48, 48);
            lv_obj_align(orb_box, LV_ALIGN_BOTTOM_MID, 0, -6);
        }
        if (full && voice_active) {
            // Listening and thinking show just the orb; words only for a reply or an error.
            if (reply || orb_state == OrbState::Error) lv_obj_remove_flag(caption, LV_OBJ_FLAG_HIDDEN);
            else lv_obj_add_flag(caption, LV_OBJ_FLAG_HIDDEN);
            lv_obj_remove_flag(status_pill, LV_OBJ_FLAG_HIDDEN);
            const char* word = orb_state == OrbState::Thinking ? "Thinking"
                               : orb_state == OrbState::Speaking ? "Speaking"
                               : orb_state == OrbState::Error ? "Something's wrong" : "Listening";
            lv_label_set_text(status_label, word);
        } else {
            lv_obj_add_flag(caption, LV_OBJ_FLAG_HIDDEN);
            lv_obj_add_flag(status_pill, LV_OBJ_FLAG_HIDDEN);
        }
        ApplyOrbState();
    }

    // The pre-rendered orb: speed and a gentle pulse say what state it's in.
    void ApplyFramesState() {
        lv_anim_delete(orb_img, nullptr);
        lv_image_set_scale(orb_img, LV_SCALE_NONE);
        bool error = orb_state == OrbState::Error;
        lv_obj_set_style_image_recolor(orb_img, lv_color_hex(settings.theme.danger), 0);
        lv_obj_set_style_image_recolor_opa(orb_img, error ? 120 : 0, 0);
        // 150 frames span the shader's 38.4 s cycle (0.26 s apart): idle runs it in ~17 s,
        // smooth at 9 fps; activity plays it faster.
        // No scale pulse: a transformed 160 px image every frame starved the other tasks
        // (mic streaming) of the display lock. Speed alone shows the state.
        uint32_t period = 111;
        switch (orb_state) {
            case OrbState::Idle: period = 111; break;
            case OrbState::Listening: period = 80; break;
            case OrbState::Thinking: period = 70; break;
            case OrbState::Speaking: period = 75; break;
            case OrbState::Error: period = 100; break;
        }
        lv_timer_set_period(orb_timer, period);
    }

    void ApplyOrbState() {
        // Frames only draw at their native size (LVGL scaling of them renders a solid box),
        // so the small in-page indicator uses the drawn orb.
        bool frames = orb_img && OrbFull();
        if (orb_img) {
            if (frames) lv_obj_remove_flag(orb_img, LV_OBJ_FLAG_HIDDEN);
            else lv_obj_add_flag(orb_img, LV_OBJ_FLAG_HIDDEN);
            for (lv_obj_t* o : {glow, mid, core}) {
                if (frames) lv_obj_add_flag(o, LV_OBJ_FLAG_HIDDEN);
                else lv_obj_remove_flag(o, LV_OBJ_FLAG_HIDDEN);
            }
        }
        if (frames) return ApplyFramesState();
        for (lv_obj_t* o : {glow, mid, core}) lv_anim_delete(o, nullptr);
        if (!kAnimateOrb) {
            bool small = !OrbBig();
            lv_color_t still = lv_color_hex(orb_state == OrbState::Error ? settings.theme.danger : settings.theme.accent);
            for (lv_obj_t* o : {glow, mid, core}) lv_obj_set_style_bg_color(o, still, 0);
            lv_obj_set_style_bg_opa(glow, 40, 0);
            lv_obj_set_style_bg_opa(mid, 70, 0);
            SizeAnim(glow, small ? 46 : 196);
            SizeAnim(mid, small ? 36 : 150);
            SizeAnim(core, small ? 24 : 92);
            return;
        }
        bool full = OrbFull();
        int s = full ? 1 : 0;
        lv_color_t accent = lv_color_hex(orb_state == OrbState::Error ? settings.theme.danger : settings.theme.accent);
        lv_obj_set_style_bg_color(glow, accent, 0);
        lv_obj_set_style_bg_color(mid, accent, 0);
        lv_obj_set_style_bg_color(core, lv_color_mix(kWhite, accent, 70), 0);
        lv_obj_set_style_shadow_color(core, accent, 0);
        lv_obj_set_style_shadow_width(core, full ? 40 : 12, 0);
        lv_obj_set_style_shadow_opa(core, LV_OPA_80, 0);
        auto size = [&](int big, int small) { return s ? big : small; };
        lv_obj_set_style_bg_opa(mid, 70, 0);
        SizeAnim(mid, size(150, 36));
        SizeAnim(glow, size(196, 46));
        switch (orb_state) {
            case OrbState::Idle:
                Pulse(core, SizeAnim, size(86, 22), size(98, 26), 2600);
                Pulse(glow, OpaAnim, 25, 60, 2600);
                break;
            case OrbState::Listening:
                Pulse(core, SizeAnim, size(96, 24), size(126, 32), 520);
                Pulse(glow, OpaAnim, 60, 140, 520);
                break;
            case OrbState::Thinking:
                Pulse(mid, SizeAnim, size(140, 32), size(172, 42), 700);
                Pulse(core, SizeAnim, size(88, 22), size(96, 25), 260);
                Pulse(glow, OpaAnim, 40, 90, 700);
                break;
            case OrbState::Speaking:
                Pulse(core, SizeAnim, size(94, 24), size(136, 34), 340);
                Pulse(glow, OpaAnim, 90, 190, 340);
                break;
            case OrbState::Error:
                Pulse(core, SizeAnim, size(90, 22), size(120, 30), 180, 3);
                lv_obj_set_style_bg_opa(glow, 120, 0);
                break;
        }
    }

    void LoadOrbFrames() {
        const esp_partition_t* part = esp_partition_find_first(ESP_PARTITION_TYPE_DATA,
                                                               static_cast<esp_partition_subtype_t>(0x40), "orb");
        if (!part) return;
        const void* ptr = nullptr;
        esp_partition_mmap_handle_t handle;
        if (esp_partition_mmap(part, 0, part->size, ESP_PARTITION_MMAP_DATA, &ptr, &handle) != ESP_OK) return;
        const auto* base = static_cast<const uint8_t*>(ptr);
        uint32_t count, w, h;
        memcpy(&count, base + 4, 4);
        memcpy(&w, base + 8, 4);
        memcpy(&h, base + 12, 4);
        size_t frame_bytes = static_cast<size_t>(w) * h * 2;
        if (memcmp(base, "ORB1", 4) != 0 || count == 0 || count > 512 || w == 0 || w > 240 || h == 0 || h > 240 ||
            16 + count * frame_bytes > part->size) {
            ESP_LOGW(TAG, "orb partition has no frames; using the drawn orb");
            esp_partition_munmap(handle);
            return;
        }
        for (uint32_t i = 0; i < count; ++i) {
            lv_image_dsc_t dsc = {};
            dsc.header.magic = LV_IMAGE_HEADER_MAGIC;
            dsc.header.cf = LV_COLOR_FORMAT_RGB565;
            dsc.header.w = w;
            dsc.header.h = h;
            dsc.header.stride = w * 2;
            dsc.data_size = frame_bytes;
            dsc.data = base + 16 + i * frame_bytes;
            orb_frames.push_back(dsc);
        }
        ESP_LOGI(TAG, "orb: %u frames %ux%u from flash", (unsigned)count, (unsigned)w, (unsigned)h);
    }

    void BuildOrb() {
        orb_layer = Layer(root, true);
        orb_box = lv_obj_create(orb_layer);
        lv_obj_remove_style_all(orb_box);
        lv_obj_remove_flag(orb_box, LV_OBJ_FLAG_SCROLLABLE);
        glow = Circle(orb_box, 196);
        mid = Circle(orb_box, 150);
        core = Circle(orb_box, 90);
        LoadOrbFrames();
        if (!orb_frames.empty()) {
            for (lv_obj_t* o : {glow, mid, core}) lv_obj_add_flag(o, LV_OBJ_FLAG_HIDDEN);
            orb_img = lv_image_create(orb_box);
            SetOrbMorph(0);
            orb_timer = lv_timer_create(
                [](lv_timer_t* t) {
                    auto* impl = static_cast<Impl*>(lv_timer_get_user_data(t));
                    if (impl->orb_morph) return;  // the reply layout draws a scaled copy
                    impl->orb_frame = (impl->orb_frame + 1) % static_cast<int>(impl->orb_frames.size());
                    lv_image_set_src(impl->orb_img, &impl->orb_frames[impl->orb_frame]);
                },
                125, this);
            lv_timer_pause(orb_timer);
        }
        // On the root, above the orb layer, so it can drain away after voice ends on any home.
        ring = lv_arc_create(root);
        lv_obj_remove_style_all(ring);
        lv_obj_set_size(ring, kScreen, kScreen);
        lv_obj_set_pos(ring, 0, 0);
        lv_obj_set_style_arc_width(ring, 5, LV_PART_MAIN);
        lv_obj_set_style_arc_rounded(ring, true, LV_PART_MAIN);
        lv_obj_set_style_arc_opa(ring, LV_OPA_COVER, LV_PART_MAIN);
        lv_obj_set_style_arc_opa(ring, LV_OPA_TRANSP, LV_PART_INDICATOR);
        lv_arc_set_rotation(ring, 90);
        lv_arc_set_bg_angles(ring, 0, 0);
        lv_obj_remove_flag(ring, LV_OBJ_FLAG_CLICKABLE);

        caption = lv_label_create(orb_layer);
        lv_label_set_text(caption, "");
        lv_obj_set_style_text_font(caption, &lv_font_montserrat_16, 0);
        lv_obj_set_style_text_color(caption, kWhite, 0);
        lv_obj_set_style_text_align(caption, LV_TEXT_ALIGN_CENTER, 0);
        lv_label_set_long_mode(caption, LV_LABEL_LONG_DOT);
        lv_obj_set_size(caption, 150, 20);
        lv_obj_align(caption, LV_ALIGN_TOP_MID, 0, 192);

        status_pill = lv_obj_create(orb_layer);
        lv_obj_remove_style_all(status_pill);
        lv_obj_set_size(status_pill, LV_SIZE_CONTENT, 24);
        lv_obj_set_style_radius(status_pill, 12, 0);
        lv_obj_set_style_bg_color(status_pill, lv_color_hex(0x1A1C22), 0);
        lv_obj_set_style_bg_opa(status_pill, LV_OPA_COVER, 0);
        lv_obj_set_style_pad_hor(status_pill, 10, 0);
        lv_obj_set_flex_flow(status_pill, LV_FLEX_FLOW_ROW);
        lv_obj_set_flex_align(status_pill, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
        lv_obj_set_style_pad_column(status_pill, 6, 0);
        lv_obj_remove_flag(status_pill, LV_OBJ_FLAG_SCROLLABLE);
        lv_obj_t* dot = Circle(status_pill, 7);
        lv_obj_set_style_bg_color(dot, lv_color_hex(settings.theme.accent), 0);
        status_label = lv_label_create(status_pill);
        lv_label_set_text(status_label, "Listening");
        lv_obj_set_style_text_font(status_label, &lv_font_montserrat_14, 0);
        lv_obj_set_style_text_color(status_label, kWhite, 0);
        lv_obj_align(status_pill, LV_ALIGN_TOP_MID, 0, 20);
        lv_obj_add_flag(status_pill, LV_OBJ_FLAG_HIDDEN);
        lv_obj_add_flag(orb_layer, LV_OBJ_FLAG_HIDDEN);
    }

    // ---- chrome + menu ----------------------------------------------------------
    void UpdateChrome() {
        bool system = screen == Screen::Setup || screen == Screen::System;
        if (system || menu_open) lv_obj_add_flag(menu_btn, LV_OBJ_FLAG_HIDDEN);
        else lv_obj_remove_flag(menu_btn, LV_OBJ_FLAG_HIDDEN);
        if (menu_open && !system) lv_obj_remove_flag(close_btn, LV_OBJ_FLAG_HIDDEN);
        else lv_obj_add_flag(close_btn, LV_OBJ_FLAG_HIDDEN);
        if (screen == Screen::Shown && !menu_open) lv_obj_remove_flag(back_btn, LV_OBJ_FLAG_HIDDEN);
        else lv_obj_add_flag(back_btn, LV_OBJ_FLAG_HIDDEN);
        UpdateOrbLayer();
        lv_obj_move_foreground(orb_layer);
        lv_obj_move_foreground(ring);
        lv_obj_move_foreground(menu_layer);
        lv_obj_move_foreground(menu_btn);
        lv_obj_move_foreground(close_btn);
        lv_obj_move_foreground(back_btn);
    }

    std::vector<std::pair<std::string, std::string>> homes_cache;  // saved homes, read once per menu visit

    const std::vector<std::pair<std::string, std::string>>& Homes() {
        if (homes_cache.empty()) homes_cache = store::ListHomes();
        return homes_cache;
    }

    std::string HomeTitle(const std::string& id) {
        if (id == "orb") return "Orb";
        if (id == "clock") return "Clock";
        for (auto& [hid, title] : Homes()) {
            if (hid == id) return title;
        }
        return id;
    }

    void BuildMenuRows() {
        rows.clear();
        auto& board = Board::GetInstance();
        if (!settings_menu) {
            rows.push_back({"Home", [this] { ShowHomeLocked(); }});
            rows.push_back({"Voice", [this] {
                                CloseMenu();
                                if (owner->on_voice) owner->on_voice("");
                            }});
            rows.push_back({"Settings", [this] {
                                settings_menu = true;
                                highlight = 0;
                                RenderMenu();
                            }});
            rows.push_back({"Close", [this] { CloseMenu(); }});
            return;
        }
        settings = store::LoadUi();
        rows.push_back({"Home: " + HomeTitle(settings.home), [this] {
                            std::vector<std::string> ids = {"orb", "clock"};
                            for (auto& [id, title] : Homes()) ids.push_back(id);
                            auto it = std::find(ids.begin(), ids.end(), settings.home);
                            settings.home = (it == ids.end() || it + 1 == ids.end()) ? ids[0] : *(it + 1);
                            store::SaveUi(settings);
                            Changed();
                        }});
        int brightness = board.GetBacklight() ? board.GetBacklight()->brightness() : 0;
        rows.push_back({"Brightness: " + std::to_string(brightness) + "%", [this, brightness] {
                            int next = brightness >= 100 ? 20 : ((brightness / 20) + 1) * 20;
                            if (auto* bl = Board::GetInstance().GetBacklight()) bl->SetBrightness(next, true);
                            Changed();
                        }});
        int volume = board.GetAudioCodec() ? board.GetAudioCodec()->output_volume() : 0;
        rows.push_back({"Volume: " + std::to_string(volume) + "%", [this, volume] {
                            int next = volume >= 100 ? 0 : ((volume / 25) + 1) * 25;
                            if (auto* c = Board::GetInstance().GetAudioCodec()) c->SetOutputVolume(next);
                            Changed();
                        }});
        rows.push_back({std::string("Wake word: ") + (settings.wake_word ? "On" : "Off"), [this] {
                            settings.wake_word = !settings.wake_word;
                            store::SaveUi(settings);
                            Changed();
                        }});
        auto& wifi = WifiManager::GetInstance();
        rows.push_back({"Wi-Fi: " + (wifi.IsConnected() ? wifi.GetSsid() + " " + std::to_string(wifi.GetRssi()) + " dBm" : std::string("offline")), nullptr});
        int level = 0;
        bool charging = false, discharging = false;
        if (board.GetBatteryLevel(level, charging, discharging)) {
            rows.push_back({"Battery: " + std::to_string(level) + "%" + (charging ? " charging" : ""), nullptr});
        }
        rows.push_back({std::string("About: ") + esp_app_get_description()->version + " " + wifi.GetIpAddress(), nullptr});
        rows.push_back({"Back", [this] {
                            settings_menu = false;
                            highlight = 0;
                            RenderMenu();
                        }});
    }

    void Changed() {
        homes_cache.clear();
        if (owner->on_settings_changed) owner->on_settings_changed();
        RenderMenu();
    }

    // `rebuild` false only moves the highlight: rebuilding reads NVS and the pages partition.
    void RenderMenu(bool rebuild = true) {
        if (rebuild || rows.empty()) BuildMenuRows();
        highlight = std::max(0, std::min<int>(highlight, rows.size() - 1));
        lv_obj_clean(menu_layer);
        lv_obj_t* title = lv_label_create(menu_layer);
        lv_label_set_text(title, settings_menu ? "Settings" : "Menu");
        lv_obj_set_style_text_font(title, &lv_font_montserrat_16, 0);
        lv_obj_set_style_text_color(title, kMuted, 0);
        lv_obj_align(title, LV_ALIGN_TOP_MID, 0, 26);
        // A window of five rows around the highlight: the screen is round.
        int first = std::max(0, std::min<int>(highlight - 2, static_cast<int>(rows.size()) - 5));
        for (int i = 0; i < static_cast<int>(rows.size()); ++i) {
            rows[i].obj = nullptr;
            if (i < first || i >= first + 5) continue;
            lv_obj_t* row = lv_obj_create(menu_layer);
            lv_obj_remove_style_all(row);
            lv_obj_set_size(row, 180, 32);
            lv_obj_align(row, LV_ALIGN_TOP_MID, 0, 52 + (i - first) * 34);
            lv_obj_set_style_radius(row, 16, 0);
            lv_obj_set_style_bg_color(row, lv_color_hex(settings.theme.accent), 0);
            lv_obj_set_style_bg_opa(row, i == highlight ? 90 : 0, 0);
            lv_obj_remove_flag(row, LV_OBJ_FLAG_SCROLLABLE);
            lv_obj_t* l = lv_label_create(row);
            lv_label_set_text(l, rows[i].label.c_str());
            lv_label_set_long_mode(l, LV_LABEL_LONG_DOT);
            lv_obj_set_width(l, 168);
            lv_obj_set_style_text_align(l, LV_TEXT_ALIGN_CENTER, 0);
            lv_obj_set_style_text_font(l, &lv_font_montserrat_16, 0);
            lv_obj_set_style_text_color(l, rows[i].action ? kWhite : kMuted, 0);
            lv_obj_center(l);
            rows[i].obj = row;
        }
    }

    void OpenMenu() {
        homes_cache.clear();
        menu_open = true;
        settings_menu = false;
        highlight = 0;
        lv_obj_remove_flag(menu_layer, LV_OBJ_FLAG_HIDDEN);
        RenderMenu();
        UpdateChrome();
    }

    void CloseMenu() {
        if (!menu_open) return;
        menu_open = false;
        lv_obj_add_flag(menu_layer, LV_OBJ_FLAG_HIDDEN);
        UpdateChrome();
    }

    void Select(int i) {
        if (i < 0 || i >= static_cast<int>(rows.size()) || !rows[i].action) return;
        highlight = i;
        auto action = rows[i].action;  // rows are rebuilt by the action
        action();
    }

    void Back() {
        if (menu_open) {
            if (settings_menu) {
                settings_menu = false;
                highlight = 0;
                RenderMenu();
            } else {
                CloseMenu();
            }
            return;
        }
        if (screen == Screen::Shown) ShowHomeLocked();
    }
};

Ui& Ui::Get() {
    static Ui ui;
    return ui;
}

void Ui::Init(Display* display) {
    impl_ = new Impl();
    impl_->owner = this;
    impl_->display = display;
    impl_->settings = store::LoadUi();
    DisplayLockGuard lock(display);
    auto* m = impl_;
    // Covers the upstream chat UI, which stays alive underneath for the code that still pokes it.
    m->root = Layer(lv_screen_active(), true);
    m->page_layer = Layer(m->root, false);
    m->BuildOrb();
    m->menu_layer = Layer(m->root, false);
    lv_obj_set_style_bg_color(m->menu_layer, kBlack, 0);
    lv_obj_set_style_bg_opa(m->menu_layer, 235, 0);
    lv_obj_add_flag(m->menu_layer, LV_OBJ_FLAG_HIDDEN);
    // Inset enough to clear the voice ring at the screen edge.
    m->menu_btn = GlassButton(m->root, LV_SYMBOL_BARS, 40, 40);
    m->back_btn = GlassButton(m->root, LV_SYMBOL_LEFT, 164, 40);
    m->close_btn = GlassButton(m->root, LV_SYMBOL_CLOSE, 40, 40);
    m->UpdateChrome();
    m->tick = lv_timer_create(
        [](lv_timer_t* t) {
            auto* impl = static_cast<Impl*>(lv_timer_get_user_data(t));
            impl->UpdateClock();
            render::Refresh(impl->ctx);
        },
        1000, m);
}

void Ui::ShowSetup(const std::string& qr_payload, const std::string& ssid) {
    DisplayLockGuard lock(impl_->display);
    auto* m = impl_;
    m->ClearPage();
    m->screen = Screen::Setup;
    lv_obj_t* col = m->Column(m->page_layer);
    lv_obj_set_style_pad_row(col, 4, 0);
    lv_obj_t* qr = lv_qrcode_create(col);
    lv_qrcode_set_size(qr, 132);
    lv_qrcode_set_dark_color(qr, kBlack);
    lv_qrcode_set_light_color(qr, kWhite);
    lv_qrcode_update(qr, qr_payload.data(), qr_payload.size());
    lv_obj_set_style_border_color(qr, kWhite, 0);
    lv_obj_set_style_border_width(qr, 6, 0);
    m->Text(col, "Scan in the Jarvis app", &lv_font_montserrat_14, kWhite);
    m->setup_message = m->Text(col, ssid, &lv_font_montserrat_14, kMuted);
    m->UpdateChrome();
}

void Ui::SetSetupMessage(const std::string& message) {
    DisplayLockGuard lock(impl_->display);
    if (impl_->screen == Screen::Setup && impl_->setup_message && !message.empty()) {
        lv_label_set_text(impl_->setup_message, message.c_str());
    }
}

void Ui::ShowStatus(const std::string& title, const std::string& message) {
    DisplayLockGuard lock(impl_->display);
    auto* m = impl_;
    m->CloseMenu();
    m->ClearPage();
    m->screen = Screen::System;
    lv_obj_t* col = m->Column(m->page_layer);
    m->Text(col, title, &lv_font_montserrat_20, kWhite);
    m->Text(col, message, &lv_font_montserrat_14, kMuted);
    m->UpdateChrome();
}

void Ui::ShowHome() {
    DisplayLockGuard lock(impl_->display);
    impl_->ShowHomeLocked();
}

void Ui::ShowPage(const std::string& page_json) {
    DisplayLockGuard lock(impl_->display);
    auto* m = impl_;
    if (m->screen == Screen::Setup || m->screen == Screen::System) return;
    m->CloseMenu();
    m->ClearPage();
    m->settings = store::LoadUi();
    if (!m->RenderDoc(page_json)) {
        m->ShowHomeLocked();
        return;
    }
    const cJSON* id = cJSON_GetObjectItemCaseSensitive(m->page_doc, "id");
    m->shown_id = cJSON_IsString(id) ? id->valuestring : "shown";
    m->screen = Screen::Shown;
    m->UpdateChrome();
}

void Ui::CacheImages(std::map<std::string, std::string> url_to_bytes) {
    DisplayLockGuard lock(impl_->display);
    for (auto& [url, bytes] : url_to_bytes) impl_->images[url] = std::move(bytes);
    while (impl_->images.size() > 12) impl_->images.erase(impl_->images.begin());
}

bool Ui::MergeShownData(const cJSON* data) {
    DisplayLockGuard lock(impl_->display);
    auto* m = impl_;
    if (m->screen != Screen::Shown || !m->page_doc) return false;
    cJSON* page_data = cJSON_GetObjectItemCaseSensitive(m->page_doc, "data");
    if (!cJSON_IsObject(page_data)) {
        cJSON_DeleteItemFromObjectCaseSensitive(m->page_doc, "data");
        page_data = cJSON_AddObjectToObject(m->page_doc, "data");
    }
    const cJSON* item;
    cJSON_ArrayForEach(item, data) {
        cJSON_DeleteItemFromObjectCaseSensitive(page_data, item->string);
        cJSON_AddItemToObject(page_data, item->string, cJSON_Duplicate(item, true));
    }
    char* json = cJSON_PrintUnformatted(m->page_doc);
    std::string copy = json ? json : "";
    cJSON_free(json);
    std::string shown = m->shown_id;
    m->ClearPage();
    m->RenderDoc(copy);
    m->shown_id = shown;
    m->UpdateChrome();
    return true;
}

void Ui::Back() {
    DisplayLockGuard lock(impl_->display);
    impl_->Back();
}

std::string Ui::ShownId() {
    DisplayLockGuard lock(impl_->display);
    return impl_->screen == Screen::Shown ? impl_->shown_id : "";
}

bool Ui::OnHome() {
    DisplayLockGuard lock(impl_->display);
    return impl_->screen == Screen::Home;
}

bool Ui::MenuOpen() {
    DisplayLockGuard lock(impl_->display);
    return impl_->menu_open;
}

void Ui::ToggleMenu() {
    DisplayLockGuard lock(impl_->display);
    auto* m = impl_;
    if (m->screen == Screen::Setup || m->screen == Screen::System) return;
    if (m->menu_open) m->CloseMenu();
    else m->OpenMenu();
}

void Ui::MenuNext() {
    DisplayLockGuard lock(impl_->display);
    auto* m = impl_;
    if (!m->menu_open || m->rows.empty()) return;
    m->highlight = (m->highlight + 1) % static_cast<int>(m->rows.size());
    m->RenderMenu(false);
}

void Ui::MenuSelect() {
    DisplayLockGuard lock(impl_->display);
    if (impl_->menu_open) impl_->Select(impl_->highlight);
}

void Ui::SetOrbState(OrbState state) {
    DisplayLockGuard lock(impl_->display);
    auto* m = impl_;
    m->orb_state = state;
    if (lv_obj_has_flag(m->orb_layer, LV_OBJ_FLAG_HIDDEN)) return;
    m->UpdateOrbLayer();  // re-applies the orb and the status pill's word
    if (state == OrbState::Error) {
        if (m->error_timer) lv_timer_delete(m->error_timer);
        m->error_timer = lv_timer_create(
            [](lv_timer_t* t) {
                auto* impl = static_cast<Impl*>(lv_timer_get_user_data(t));
                impl->error_timer = nullptr;
                if (impl->orb_state == OrbState::Error) {
                    impl->orb_state = OrbState::Idle;
                    impl->UpdateOrbLayer();
                }
                lv_timer_delete(t);
            },
            1500, m);
    }
}

void Ui::SetVoiceActive(bool active) {
    DisplayLockGuard lock(impl_->display);
    auto* m = impl_;
    m->voice_active = active;
    if (!active) m->orb_state = OrbState::Idle;
    if (active) m->CloseMenu();
    m->UpdateChrome();
}

void Ui::SetCaption(const std::string& text) {
    DisplayLockGuard lock(impl_->display);
    lv_label_set_text(impl_->caption, text.c_str());
    impl_->FitCaption();
}

void Ui::SetVoiceLevel(int percent) {
    DisplayLockGuard lock(impl_->display);
    auto* m = impl_;
    if (!m->ring || m->spin_timer || !m->voice_active || m->orb_state != OrbState::Listening) return;
    // Four steps, so quiet flicker doesn't redraw the screen every tick.
    m->SetRingWidth(Impl::kRingWidth + 2 * std::min(4, std::max(0, percent) / 20));
}

void Ui::OnTap(int x, int y) {
    DisplayLockGuard lock(impl_->display);
    auto* m = impl_;
    if (m->screen == Screen::Setup) return;
    if (m->menu_open) {
        if (Hit(m->close_btn, x, y)) return m->CloseMenu();
        for (int i = 0; i < static_cast<int>(m->rows.size()); ++i) {
            if (Hit(m->rows[i].obj, x, y)) return m->Select(i);
        }
        return;
    }
    if (Hit(m->menu_btn, x, y)) return m->OpenMenu();
    if (Hit(m->back_btn, x, y)) return m->Back();
    if (m->OrbVisible() && Hit(m->orb_box, x, y)) {
        if (on_voice) on_voice("");
        return;
    }
    if (m->OrbFull()) return;  // the orb covers the page
    for (auto& tap : m->ctx.taps) {
        if (!Hit(tap.obj, x, y)) continue;
        if (tap.action == "home") return m->Back();
        if (tap.action == "voice" && on_voice) on_voice(tap.text);
        return;
    }
}

void Ui::ApplySettings() {
    DisplayLockGuard lock(impl_->display);
    auto* m = impl_;
    // A change made from the Settings menu must not close it.
    bool menu_open = m->menu_open, settings_menu = m->settings_menu;
    int highlight = m->highlight;
    if (m->screen == Screen::Home) m->ShowHomeLocked();  // theme / home / clock format
    m->settings = store::LoadUi();
    if (menu_open) {
        m->menu_open = true;
        m->settings_menu = settings_menu;
        m->highlight = highlight;
        lv_obj_remove_flag(m->menu_layer, LV_OBJ_FLAG_HIDDEN);
        m->RenderMenu();
    }
    m->UpdateChrome();
}

}  // namespace jarvis
