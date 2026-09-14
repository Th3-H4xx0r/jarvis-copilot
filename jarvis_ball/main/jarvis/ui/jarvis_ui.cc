#include "jarvis_ui.h"

#include <cJSON.h>
#include <esp_app_desc.h>
#include <esp_log.h>
#include <wifi_manager.h>

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
    lv_obj_t* caption = nullptr;
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

    void UpdateOrbLayer() {
        if (!OrbVisible()) {
            lv_obj_add_flag(orb_layer, LV_OBJ_FLAG_HIDDEN);
            return;
        }
        lv_obj_remove_flag(orb_layer, LV_OBJ_FLAG_HIDDEN);
        bool full = OrbFull();
        lv_obj_set_style_bg_opa(orb_layer, full ? LV_OPA_COVER : LV_OPA_TRANSP, 0);
        if (full) {
            lv_obj_set_size(orb_box, 200, 200);
            lv_obj_align(orb_box, LV_ALIGN_CENTER, 0, -8);
        } else {
            lv_obj_set_size(orb_box, 48, 48);
            lv_obj_align(orb_box, LV_ALIGN_BOTTOM_MID, 0, -6);
        }
        if (full && voice_active) lv_obj_remove_flag(caption, LV_OBJ_FLAG_HIDDEN);
        else lv_obj_add_flag(caption, LV_OBJ_FLAG_HIDDEN);
        ApplyOrbState();
    }

    void ApplyOrbState() {
        for (lv_obj_t* o : {glow, mid, core}) lv_anim_delete(o, nullptr);
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

    void BuildOrb() {
        orb_layer = Layer(root, true);
        orb_box = lv_obj_create(orb_layer);
        lv_obj_remove_style_all(orb_box);
        lv_obj_remove_flag(orb_box, LV_OBJ_FLAG_SCROLLABLE);
        glow = Circle(orb_box, 196);
        mid = Circle(orb_box, 150);
        core = Circle(orb_box, 90);
        caption = lv_label_create(orb_layer);
        lv_label_set_text(caption, "");
        lv_obj_set_style_text_font(caption, &lv_font_montserrat_14, 0);
        lv_obj_set_style_text_color(caption, kWhite, 0);
        lv_obj_set_style_text_align(caption, LV_TEXT_ALIGN_CENTER, 0);
        lv_label_set_long_mode(caption, LV_LABEL_LONG_DOT);
        lv_obj_set_size(caption, 170, 36);
        lv_obj_align(caption, LV_ALIGN_BOTTOM_MID, 0, -22);
        lv_obj_add_flag(orb_layer, LV_OBJ_FLAG_HIDDEN);
    }

    // ---- chrome + menu ----------------------------------------------------------
    void UpdateChrome() {
        bool system = screen == Screen::Setup || screen == Screen::System;
        if (system) lv_obj_add_flag(menu_btn, LV_OBJ_FLAG_HIDDEN);
        else lv_obj_remove_flag(menu_btn, LV_OBJ_FLAG_HIDDEN);
        if (screen == Screen::Shown && !menu_open) lv_obj_remove_flag(back_btn, LV_OBJ_FLAG_HIDDEN);
        else lv_obj_add_flag(back_btn, LV_OBJ_FLAG_HIDDEN);
        UpdateOrbLayer();
        lv_obj_move_foreground(orb_layer);
        lv_obj_move_foreground(menu_layer);
        lv_obj_move_foreground(menu_btn);
        lv_obj_move_foreground(back_btn);
    }

    static std::string HomeTitle(const std::string& id) {
        if (id == "orb") return "Orb";
        if (id == "clock") return "Clock";
        for (auto& [hid, title] : store::ListHomes()) {
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
                            for (auto& [id, title] : store::ListHomes()) ids.push_back(id);
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
        if (owner->on_settings_changed) owner->on_settings_changed();
        RenderMenu();
    }

    void RenderMenu() {
        BuildMenuRows();
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
    m->menu_btn = GlassButton(m->root, LV_SYMBOL_BARS, 34, 34);
    m->back_btn = GlassButton(m->root, LV_SYMBOL_LEFT, 170, 34);
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
    m->RenderMenu();
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
    m->ApplyOrbState();
    if (state == OrbState::Error) {
        if (m->error_timer) lv_timer_delete(m->error_timer);
        m->error_timer = lv_timer_create(
            [](lv_timer_t* t) {
                auto* impl = static_cast<Impl*>(lv_timer_get_user_data(t));
                impl->error_timer = nullptr;
                if (impl->orb_state == OrbState::Error) {
                    impl->orb_state = OrbState::Idle;
                    impl->ApplyOrbState();
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
}

void Ui::OnTap(int x, int y) {
    DisplayLockGuard lock(impl_->display);
    auto* m = impl_;
    if (m->screen == Screen::Setup) return;
    if (m->menu_open) {
        if (Hit(m->menu_btn, x, y)) return m->CloseMenu();
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
    if (m->screen == Screen::Home) m->ShowHomeLocked();  // theme / home / clock format
    else {
        m->settings = store::LoadUi();
        m->UpdateChrome();
    }
    if (m->menu_open) m->RenderMenu();
}

}  // namespace jarvis
