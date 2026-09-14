// JARVIS: replaces xiaozhi's Application. Same class name and the subset of its API the
// kept upstream files call (boards/common, display, led), so those compile unmodified.
#pragma once

#include <freertos/FreeRTOS.h>
#include <freertos/queue.h>

#include <atomic>
#include <functional>
#include <string>
#include <string_view>

#include "audio_service.h"
#include "device_state.h"
#include "jarvis/voice/jarvis_voice.h"

class Application {
public:
    static Application& GetInstance() {
        static Application instance;
        return instance;
    }
    Application(const Application&) = delete;
    Application& operator=(const Application&) = delete;

    void Initialize();
    void Run();

    // ---- upstream-facing API ----
    DeviceState GetDeviceState() const { return state_.load(); }
    bool SetDeviceState(DeviceState state);
    bool IsVoiceDetected() const { return audio_service_.IsVoiceDetected(); }
    void Schedule(std::function<void()>&& callback);
    void Alert(const char* status, const char* message, const char* emotion = "", const std::string_view& sound = "");
    void DismissAlert() {}
    void ToggleChatState();
    bool CanEnterSleepMode();
    void PlaySound(const std::string_view& sound) { audio_service_.PlaySound(sound); }
    AudioService& GetAudioService() { return audio_service_; }
    void ResetProtocol() {}
    void Reboot();

    // ---- Jarvis ----
    void OnButtonClick();
    void OnButtonDoubleClick();
    void OnButtonLongPress();
    void OnFactoryReset();
    void OnTouchTap(int x, int y);
    void OnWifiUnavailable();
    void OnSettingsChanged();  // any thread
    void WakeScreen();         // main task
    jarvis::Voice& voice() { return voice_; }

private:
    Application() = default;
    void OnWifiConnected();

    std::atomic<DeviceState> state_{kDeviceStateStarting};
    AudioService audio_service_;
    jarvis::Voice voice_;
    QueueHandle_t queue_ = nullptr;
    bool network_up_ = false;
    bool setup_mode_ = false;
};
