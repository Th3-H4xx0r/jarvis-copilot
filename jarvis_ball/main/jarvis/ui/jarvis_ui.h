// The ball's whole UI, drawn on its own LVGL layer above the upstream display.
// Pages: saved homes (orb, clock, custom) and one temporary "shown" page.
// System chrome: ≡ menu (top-left), ‹ back (top-right, off-home), voice orb overlay.
// All public methods are thread-safe (they take the display lock).
#pragma once

#include <lvgl.h>

#include <deque>
#include <functional>
#include <map>
#include <string>
#include <vector>

#include "jarvis/store/jarvis_store.h"

class Display;
struct cJSON;

namespace jarvis {

// JSON page → LVGL (page_renderer.cc). Called with the display lock held.
namespace render {
struct Tap {
    lv_obj_t* obj;
    std::string action;
    std::string text;
};
struct Live {  // re-evaluated every second: clocks, timers, built-in bindings
    lv_obj_t* label;
    const cJSON* node;
    const char* prop;
};
struct Ctx {
    store::Theme theme;
    bool clock_24h = false;
    const cJSON* data = nullptr;
    const std::map<std::string, std::string>* images = nullptr;
    std::vector<Tap> taps;
    std::vector<Live> live;
    std::deque<std::string> image_bytes;  // stable storage the image descriptors point into
    std::deque<lv_image_dsc_t> image_dscs;
};
lv_obj_t* Build(lv_obj_t* parent, const cJSON* node, Ctx& ctx);
void Refresh(Ctx& ctx);
lv_color_t Color(const std::string& token, const store::Theme& theme);
const lv_font_t* Font(int size);
std::string ClockText(bool clock_24h, const char* format);
}  // namespace render

enum class OrbState { Idle, Listening, Thinking, Speaking, Error };

class Ui {
public:
    static Ui& Get();

    void Init(Display* display);

    // System screens
    void ShowSetup(const std::string& qr_payload, const std::string& ssid);
    void SetSetupMessage(const std::string& message);
    void ShowStatus(const std::string& title, const std::string& message);

    // Pages
    void ShowHome();  // settings.home: orb | clock | saved id
    // Validated page JSON → temporary page. https images must already be cached.
    void ShowPage(const std::string& page_json);
    void CacheImages(std::map<std::string, std::string> url_to_bytes);
    bool MergeShownData(const cJSON* data);
    void Back();
    std::string ShownId();
    bool OnHome();

    // Menu
    bool MenuOpen();
    void ToggleMenu();
    void MenuNext();
    void MenuSelect();

    // Voice
    void SetOrbState(OrbState state);
    void SetVoiceActive(bool active);  // overlay while a turn runs (unless home is the orb page)
    void SetCaption(const std::string& text);
    void SetVoiceLevel(int percent);  // mic level while listening: pulses the ring

    void OnTap(int x, int y);
    void ApplySettings();  // theme / clock format / home changed

    // Wired by Application.
    std::function<void(const std::string& text)> on_voice;  // tap on orb / voice action
    std::function<void()> on_settings_changed;               // menu changed a setting

private:
    Ui() = default;
    struct Impl;
    Impl* impl_ = nullptr;
};

}  // namespace jarvis
