// JARVIS: the ball's application. Owns the main task, wires audio → voice, buttons and
// touch → UI, and decides at boot between setup mode and the paired experience.
#include "application.h"

#include <esp_log.h>
#include <esp_netif_sntp.h>
#include <esp_system.h>
#include <esp_timer.h>
#include <freertos/task.h>

#include <cstdlib>
#include <ctime>

#include "board.h"
#include "display.h"
#include "jarvis/board_caps.h"
#include "jarvis/link/jarvis_link.h"
#include "jarvis/setup/jarvis_setup.h"
#include "jarvis/store/jarvis_store.h"
#include "jarvis/ui/jarvis_ui.h"

#define TAG "Application"

using jarvis::Ui;

bool Application::SetDeviceState(DeviceState state) {
    state_ = state;
    return true;
}

void Application::Schedule(std::function<void()>&& callback) {
    auto* fn = new std::function<void()>(std::move(callback));
    // Never block the caller: audio, socket and button tasks all post here.
    if (!queue_ || xQueueSend(queue_, &fn, 0) != pdTRUE) {
        ESP_LOGW(TAG, "main queue full, dropping a task");
        delete fn;
    }
}

void Application::Alert(const char* status, const char* message, const char* emotion, const std::string_view& sound) {
    (void)emotion;
    (void)sound;
    ESP_LOGW(TAG, "alert: %s %s", status, message);
}

void Application::ToggleChatState() {
    Schedule([this]() { voice_.Trigger(); });
}

bool Application::CanEnterSleepMode() { return !voice_.Busy() && !setup_mode_; }

void Application::Reboot() { esp_restart(); }

static void ApplyTimezone(const jarvis::store::UiSettings& ui) {
    setenv("TZ", ui.tz_posix.empty() ? "UTC0" : ui.tz_posix.c_str(), 1);
    tzset();
}

void Application::Initialize() {
    queue_ = xQueueCreate(64, sizeof(std::function<void()>*));
    auto& board = Board::GetInstance();  // constructs the board: probes codec + touch
    auto* display = board.GetDisplay();
    display->SetupUI();
    Ui::Get().Init(display);

    if (!jarvis::Caps().codec_present) {
        ESP_LOGE(TAG, "ES8311 not found: unsupported board revision");
        Ui::Get().ShowStatus("Hardware check failed", "Unsupported board revision");
        SetDeviceState(kDeviceStateFatalError);
        return;
    }

    jarvis::store::MountPages();
    audio_service_.Initialize(board.GetAudioCodec());
    audio_service_.Start();
    AudioServiceCallbacks callbacks;
    callbacks.on_send_queue_available = [this]() {
        if (voice_.NeedsMicWakeup()) Schedule([this]() { voice_.SendMic(); });
    };
    callbacks.on_wake_word_detected = [this](const std::string&) { Schedule([this]() { voice_.Trigger(); }); };
    callbacks.on_vad_change = [this](bool speaking) { Schedule([this, speaking]() { voice_.OnVad(speaking); }); };
    callbacks.on_playback_drained = [this]() { Schedule([this]() { voice_.OnPlaybackDrained(); }); };
    audio_service_.SetCallbacks(callbacks);

    Ui::Get().on_voice = [this](const std::string& text) { Schedule([this, text]() { voice_.Trigger(text); }); };
    Ui::Get().on_settings_changed = [this]() { OnSettingsChanged(); };

    auto pairing = jarvis::store::LoadPairing();
    if (!pairing.paired()) {
        setup_mode_ = true;
        SetDeviceState(kDeviceStateWifiConfiguring);
        jarvis::Setup::Get().Start();
        return;
    }

    auto ui = jarvis::store::LoadUi();
    ApplyTimezone(ui);
    jarvis::RegisterBallTools();
    jarvis::Link::Get().on_state = [](jarvis::LinkState s) {
        if (s == jarvis::LinkState::Unpaired) {
            Ui::Get().ShowStatus("Unpaired", "Jarvis unpaired this ball. Hold BOOT 5 s to set up again.");
        }
    };
    Ui::Get().ShowStatus("Connecting", "Joining Wi-Fi…");
    board.SetNetworkEventCallback([this](NetworkEvent event, const std::string& data) {
        if (event == NetworkEvent::Connected) {
            Schedule([this]() { OnWifiConnected(); });
        } else if (event == NetworkEvent::Disconnected && network_up_) {
            ESP_LOGW(TAG, "Wi-Fi dropped");
        } else if (event == NetworkEvent::Connecting && !network_up_) {
            Ui::Get().ShowStatus("Connecting", "Joining " + data + "…");
        }
    });
    board.StartNetwork();
    SetDeviceState(kDeviceStateConnecting);
}

void Application::OnWifiConnected() {
    if (network_up_) return;
    network_up_ = true;
    esp_sntp_config_t sntp = ESP_NETIF_SNTP_DEFAULT_CONFIG("time.apple.com");
    esp_netif_sntp_init(&sntp);
    voice_.Init(&audio_service_);
    jarvis::Link::Get().Start();
    Ui::Get().ShowHome();
    SetDeviceState(kDeviceStateIdle);
}

void Application::OnWifiUnavailable() {
    Schedule([this]() {
        if (network_up_) return;
        Ui::Get().ShowStatus("No Wi-Fi", "Can't reach your network. Still trying. Hold BOOT 5 s to set up again.");
    });
}

void Application::OnSettingsChanged() {
    Schedule([this]() {
        ApplyTimezone(jarvis::store::LoadUi());
        if (network_up_) voice_.ApplyWakeWord();
        Ui::Get().ApplySettings();
    });
}

void Application::WakeScreen() {
    // The power-save timer dims the screen after 60 s on battery; any interaction wakes it.
    if (!setup_mode_) Board::GetInstance().SetPowerSaveLevel(PowerSaveLevel::BALANCED);
}

void Application::OnButtonClick() {
    Schedule([this]() {
        if (setup_mode_) return;
        WakeScreen();
        if (Ui::Get().MenuOpen()) Ui::Get().MenuNext();
        else if (network_up_) voice_.Trigger();
    });
}

void Application::OnButtonDoubleClick() {
    Schedule([this]() {
        if (setup_mode_) return;
        WakeScreen();
        Ui::Get().ToggleMenu();
    });
}

void Application::OnButtonLongPress() {
    Schedule([this]() {
        if (setup_mode_) return;
        WakeScreen();
        if (Ui::Get().MenuOpen()) Ui::Get().MenuSelect();
        else Ui::Get().Back();
    });
}

void Application::OnFactoryReset() {
    Schedule([]() {
        Ui::Get().ShowStatus("Resetting", "Forgetting Wi-Fi and pairing…");
        jarvis::store::FactoryReset();
        vTaskDelay(pdMS_TO_TICKS(800));
        esp_restart();
    });
}

void Application::OnTouchTap(int x, int y) {
    Schedule([this, x, y]() {
        WakeScreen();
        Ui::Get().OnTap(x, y);
    });
}

void Application::Run() {
    int64_t last_tick = 0;
    for (;;) {
        std::function<void()>* fn = nullptr;
        if (xQueueReceive(queue_, &fn, pdMS_TO_TICKS(100)) == pdTRUE && fn) {
            (*fn)();
            delete fn;
        }
        int64_t now = esp_timer_get_time() / 1000;
        if (network_up_ && now - last_tick >= 100) {
            last_tick = now;
            voice_.Tick();
            SetDeviceState(voice_.Busy() ? kDeviceStateListening : kDeviceStateIdle);
        }
    }
}
