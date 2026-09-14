// Talking to Jarvis through the ball: the same /api/voice/s2s/ws socket and shared
// voice session the phone and Mac use, with Opus audio and on-device endpointing.
// Every method except the WS callbacks runs on the Application main task.
#pragma once

#include <atomic>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

class AudioService;
class WebSocket;

namespace jarvis {

class Voice {
public:
    void Init(AudioService* audio);

    void Trigger(const std::string& text = "");  // wake word / tap / button / page action
    void Interrupt();
    void OnVad(bool speaking);
    void SendMic();
    void OnPlaybackDrained();
    void Tick();  // ~every 100 ms
    void ApplyWakeWord();

    bool Busy() const { return phase_ != Phase::Idle; }

private:
    enum class Phase { Idle, Listening, Thinking, Speaking };

    bool EnsureConnected();
    void CloseSocket();
    void BeginTurn();
    void EndTurn();
    void FinishTurn();
    void GoIdle();
    void HandleJson(const std::string& text);
    void SendText(const std::string& json);

    AudioService* audio_ = nullptr;
    std::unique_ptr<WebSocket> ws_;
    std::atomic<bool> ready_{false};
    std::atomic<bool> socket_closed_{true};
    std::atomic<bool> discard_audio_{false};
    bool session_started_ = false;  // begin_turn sent on this socket
    std::string session_id_;

    Phase phase_ = Phase::Idle;
    bool follow_up_ = false;
    bool speech_seen_ = false;
    bool server_done_ = false;
    int64_t turn_start_ms_ = 0;
    int64_t silence_since_ms_ = 0;
    int64_t last_turn_end_ms_ = 0;
    int64_t discard_since_ms_ = 0;
    std::vector<std::string> spoken_;  // assistant_text of the current reply, in order
};

}  // namespace jarvis
