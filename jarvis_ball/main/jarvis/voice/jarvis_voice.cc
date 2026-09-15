#include "jarvis_voice.h"

#include <cJSON.h>
#include <esp_log.h>
#include <esp_timer.h>
#include <freertos/FreeRTOS.h>
#include <freertos/task.h>
#include <web_socket.h>

#include "application.h"
#include "audio_service.h"
#include "board.h"
#include "jarvis/link/jarvis_link.h"
#include "jarvis/logic/jarvis_logic.h"
#include "jarvis/store/jarvis_store.h"
#include "jarvis/ui/jarvis_ui.h"
#include "protocol.h"

#define TAG "JarvisVoice"

namespace jarvis {

namespace {
constexpr int64_t kEndSilenceMs = 700;
// A tap's click or a cough isn't a request: speech must run this long before the
// silence after it can end the turn, and the first moments after a tap are ignored.
constexpr int64_t kMinSpeechMs = 300;
constexpr int64_t kTapGuardMs = 350;
// Conversation mode: listening continues until a tap, a stop phrase, or this long with no speech.
constexpr int64_t kListenCapMs = 120000;

bool IsStopPhrase(std::string text) {
    std::string t;
    for (char c : text) {
        if (isalpha(static_cast<unsigned char>(c)) || c == ' ' || c == '\'') t.push_back(static_cast<char>(tolower(c)));
    }
    while (!t.empty() && t.back() == ' ') t.pop_back();
    while (!t.empty() && t.front() == ' ') t.erase(0, 1);
    static const char* kStops[] = {"stop", "stop listening", "nothing", "never mind", "nevermind", "that's all",
                                   "thats all", "that's it", "thats it", "cancel", "goodbye", "bye", "no thanks",
                                   "no thank you", "i'm done", "im done", "jarvis stop", "okay stop", "ok stop"};
    for (const char* s : kStops) {
        if (t == s) return true;
    }
    return false;
}
constexpr int64_t kMaxTurnMs = 15000;
constexpr int64_t kSocketIdleMs = 60000;
constexpr int64_t kDiscardExpiryMs = 10000;
constexpr int64_t kReplyWatchdogMs = 45000;
constexpr int64_t kErrorVisibleMs = 2500;

int64_t NowMs() { return esp_timer_get_time() / 1000; }
}  // namespace

void Voice::Init(AudioService* audio) {
    audio_ = audio;
    ApplyWakeWord();
}

void Voice::ApplyWakeWord() {
    if (!audio_) return;
    audio_->EnableWakeWordDetection(phase_ == Phase::Idle && store::LoadUi().wake_word);
}

void Voice::SendText(const std::string& json) {
    if (ws_ && ws_->IsConnected()) ws_->Send(json);
}

bool Voice::EnsureConnected() {
    if (ws_ && ws_->IsConnected() && ready_ && !socket_closed_) return true;
    CloseSocket();
    store::Pairing pairing = store::LoadPairing();
    if (!pairing.paired()) return false;

    HttpResult r = HttpRequest("GET", logic::JoinUrl(pairing.server, "/api/voice/session"), "", pairing, true, 6000);
    if (r.status != 200) {
        ESP_LOGW(TAG, "voice session: status %d %s", r.status, r.error.c_str());
        return false;
    }
    cJSON* body = cJSON_Parse(r.body.c_str());
    const cJSON* sid = cJSON_GetObjectItemCaseSensitive(body, "session_id");
    session_id_ = cJSON_IsString(sid) ? sid->valuestring : "";
    cJSON_Delete(body);

    ws_ = Board::GetInstance().GetNetwork()->CreateWebSocket(2);
    ApplyAuthHeaders(*ws_, pairing);
    ws_->SetReceiveBufferSize(8192);
    ready_ = false;
    socket_closed_ = false;
    ws_->OnData([this](const char* data, size_t len, bool binary) {
        if (binary) {
            if (discard_audio_) return;
            auto packet = std::make_unique<AudioStreamPacket>();
            packet->sample_rate = 24000;
            packet->frame_duration = 60;
            packet->payload.assign(data, data + len);
            audio_->PushPacketToDecodeQueue(std::move(packet), true);
            return;
        }
        std::string text(data, len);
        if (text.find("\"ready\"") != std::string::npos) {
            ready_ = true;
            return;
        }
        Application::GetInstance().Schedule([this, text]() { HandleJson(text); });
    });
    ws_->OnDisconnected([this]() {
        socket_closed_ = true;
        Application::GetInstance().Schedule([this]() {
            if (phase_ != Phase::Idle) FailTurn("Lost the connection to Jarvis");
        });
    });
    std::string url = logic::WsUrl(pairing.server, "/api/voice/s2s/ws");
    if (!ws_->Connect(url.c_str())) {
        ESP_LOGW(TAG, "voice socket connect failed");
        ws_.reset();
        return false;
    }
    for (int i = 0; i < 30 && !ready_; ++i) vTaskDelay(pdMS_TO_TICKS(100));
    if (!ready_) {
        CloseSocket();
        return false;
    }
    return true;
}

void Voice::CloseSocket() {
    if (ws_) {
        ws_->Close();
        ws_.reset();
    }
    ready_ = false;
    socket_closed_ = true;
    session_started_ = false;
}

// Once per socket, like the phone: the server takes and clears the mic buffer at each
// end_turn itself, and a second begin_turn would re-arm an interrupted reply's audio.
void Voice::BeginTurn() {
    spoken_.clear();
    server_done_ = false;
    if (session_started_) return;
    session_started_ = true;
    cJSON* msg = cJSON_CreateObject();
    cJSON_AddStringToObject(msg, "type", "begin_turn");
    cJSON_AddStringToObject(msg, "session_id", session_id_.c_str());
    cJSON_AddNumberToObject(msg, "sample_rate", 16000);
    cJSON_AddStringToObject(msg, "codec", "opus");
    cJSON_AddStringToObject(msg, "client", "jarvis_ball");
    char* s = cJSON_PrintUnformatted(msg);
    SendText(s);
    cJSON_free(s);
    cJSON_Delete(msg);
}

void Voice::Trigger(const std::string& text) {
    if (!audio_) return;  // Wi-Fi isn't up yet
    if (phase_ != Phase::Idle) {
        ESP_LOGI(TAG, "turn: tapped while active, stopping");
        if (phase_ == Phase::Speaking || phase_ == Phase::Thinking) Interrupt();
        GoIdle();  // a tap turns voice off, whatever it was doing
        return;
    }
    hide_overlay_at_ms_ = 0;
    Board::GetInstance().SetPowerSaveLevel(PowerSaveLevel::PERFORMANCE);  // wakes the dimmed screen too
    audio_->EnableWakeWordDetection(false);
    Ui::Get().SetVoiceActive(true);
    Ui::Get().SetCaption(text.empty() ? "Go ahead, I'm here." : text);
    Ui::Get().SetOrbState(text.empty() ? OrbState::Listening : OrbState::Thinking);
    if (text.empty()) audio_->EnableVoiceProcessing(true);  // start capturing while we connect

    if (!EnsureConnected()) {
        ESP_LOGW(TAG, "turn: could not connect the voice socket");
        FailTurn("Can't reach Jarvis");
        return;
    }
    ESP_LOGI(TAG, "turn: socket ready (text=%d)", !text.empty());
    BeginTurn();
    turn_start_ms_ = NowMs();
    last_server_ms_ = NowMs();
    speech_seen_ = false;
    speech_start_ms_ = 0;
    silence_since_ms_ = 0;
    last_heard_ms_ = NowMs();
    follow_up_ = false;
    if (!text.empty()) {
        cJSON* msg = cJSON_CreateObject();
        cJSON_AddStringToObject(msg, "type", "end_turn");
        cJSON_AddStringToObject(msg, "text", text.c_str());
        char* s = cJSON_PrintUnformatted(msg);
        SendText(s);
        cJSON_free(s);
        cJSON_Delete(msg);
        phase_ = Phase::Thinking;
        return;
    }
    phase_ = Phase::Listening;
}

void Voice::SendMic() {
    mic_pending_ = false;
    if (!audio_) return;
    static int sent = 0;
    while (auto packet = audio_->PopPacketFromSendQueue()) {
        if (phase_ == Phase::Listening && ws_ && ws_->IsConnected()) {
            ws_->Send(packet->payload.data(), packet->payload.size(), true);
            if (++sent % 50 == 1) ESP_LOGI(TAG, "mic: %d packets sent (%u bytes last)", sent, (unsigned)packet->payload.size());
        }
    }
}

void Voice::OnVad(bool speaking) {
    ESP_LOGI(TAG, "vad: %s (phase %d)", speaking ? "speech" : "silence", static_cast<int>(phase_));
    if (phase_ != Phase::Listening) return;
    int64_t now = NowMs();
    if (now - turn_start_ms_ < kTapGuardMs) return;
    if (speaking) {
        if (!speech_start_ms_) speech_start_ms_ = now;
        silence_since_ms_ = 0;
        return;
    }
    if (speech_start_ms_ && now - speech_start_ms_ >= kMinSpeechMs) speech_seen_ = true;
    speech_start_ms_ = 0;
    if (speech_seen_) silence_since_ms_ = now;
}

void Voice::EndTurn() {
    SendMic();  // flush what's queued before the end marker
    char msg[96];
    snprintf(msg, sizeof(msg), "{\"type\":\"end_turn\",\"client_ts\":%lld}", static_cast<long long>(NowMs()));
    SendText(msg);
    ESP_LOGI(TAG, "turn: end_turn sent");
    audio_->EnableVoiceProcessing(false);
    while (audio_->PopPacketFromSendQueue()) {}
    phase_ = Phase::Thinking;
    last_server_ms_ = NowMs();
    Ui::Get().SetOrbState(OrbState::Thinking);
}

void Voice::Interrupt() {
    std::string heard;
    // Everything but the sentence still playing counts as heard.
    for (size_t i = 0; i + 1 < spoken_.size(); ++i) heard += (heard.empty() ? "" : " ") + spoken_[i];
    cJSON* msg = cJSON_CreateObject();
    cJSON_AddStringToObject(msg, "type", "interrupt");
    cJSON_AddStringToObject(msg, "heard", heard.c_str());
    char* s = cJSON_PrintUnformatted(msg);
    SendText(s);
    cJSON_free(s);
    cJSON_Delete(msg);
    // Only a reply still on the wire has frames to throw away; once its end_turn has
    // arrived nothing would ever clear the flag.
    if (!server_done_) {
        discard_audio_ = true;
        discard_since_ms_ = NowMs();
    }
    audio_->ResetDecoder();
}

void Voice::FinishTurn() {
    last_turn_end_ms_ = NowMs();
    // Follow-up window: listen again without the wake word.
    audio_->EnableVoiceProcessing(true);
    BeginTurn();
    phase_ = Phase::Listening;
    follow_up_ = true;
    speech_seen_ = false;
    speech_start_ms_ = 0;
    silence_since_ms_ = 0;
    turn_start_ms_ = NowMs();
    Ui::Get().SetOrbState(OrbState::Listening);
}

void Voice::GoIdle() {
    phase_ = Phase::Idle;
    follow_up_ = false;
    audio_->EnableVoiceProcessing(false);
    while (audio_->PopPacketFromSendQueue()) {}
    last_turn_end_ms_ = NowMs();
    hide_overlay_at_ms_ = 0;
    Ui::Get().SetVoiceActive(false);
    Board::GetInstance().SetPowerSaveLevel(PowerSaveLevel::BALANCED);
    ApplyWakeWord();
}

void Voice::FailTurn(const std::string& message) {
    phase_ = Phase::Idle;
    follow_up_ = false;
    audio_->EnableVoiceProcessing(false);
    while (audio_->PopPacketFromSendQueue()) {}
    last_turn_end_ms_ = NowMs();
    Ui::Get().SetCaption(message);
    Ui::Get().SetOrbState(OrbState::Error);
    hide_overlay_at_ms_ = NowMs() + kErrorVisibleMs;  // Tick hides it
}

void Voice::HandleJson(const std::string& text) {
    cJSON* msg = cJSON_Parse(text.c_str());
    const cJSON* type = cJSON_GetObjectItemCaseSensitive(msg, "type");
    const cJSON* body = cJSON_GetObjectItemCaseSensitive(msg, "text");
    std::string t = cJSON_IsString(type) ? type->valuestring : "";
    std::string s = cJSON_IsString(body) ? body->valuestring : "";
    last_server_ms_ = NowMs();
    ESP_LOGI(TAG, "server: %s %.60s", t.c_str(), s.c_str());

    if (discard_audio_) {
        // Frames of the interrupted reply are still arriving until its end_turn.
        if (t == "end_turn" || NowMs() - discard_since_ms_ > kDiscardExpiryMs) discard_audio_ = false;
        cJSON_Delete(msg);
        return;
    }
    if (t == "transcript") {
        if (IsStopPhrase(s)) {
            // "Stop" / "nothing" / "that's all": cut the reply the server is starting and stop listening.
            ESP_LOGI(TAG, "turn: stop phrase \"%s\"", s.c_str());
            SendText("{\"type\":\"interrupt\",\"heard\":\"\"}");
            discard_audio_ = true;
            discard_since_ms_ = NowMs();
            audio_->ResetDecoder();
            Ui::Get().SetCaption("Okay");
            GoIdle();
            cJSON_Delete(msg);
            return;
        }
        if (!s.empty()) {
            last_heard_ms_ = NowMs();
            Ui::Get().SetCaption(s);
        }
    } else if (t == "assistant_text") {
        spoken_.push_back(s);
        Ui::Get().SetCaption(s);
    } else if (t == "tool") {
        if (phase_ != Phase::Speaking) Ui::Get().SetOrbState(OrbState::Thinking);
    } else if (t == "audio_meta") {
        phase_ = Phase::Speaking;
        Ui::Get().SetOrbState(OrbState::Speaking);
    } else if (t == "error") {
        const cJSON* e = cJSON_GetObjectItemCaseSensitive(msg, "error");
        FailTurn(cJSON_IsString(e) ? e->valuestring : "Something went wrong");
    } else if (t == "end_turn") {
        const cJSON* reason = cJSON_GetObjectItemCaseSensitive(msg, "reason");
        std::string r = cJSON_IsString(reason) ? reason->valuestring : "";
        server_done_ = true;
        if (hide_overlay_at_ms_) {
            // An error is on screen; let it stay its full time.
        } else if (r == "error") {
            GoIdle();
        } else if (r == "no_speech") {
            FinishTurn();  // nothing understood: keep listening (a tap, "stop" or 2 quiet minutes end it)
        } else if (phase_ != Phase::Speaking || audio_->IsPlaybackIdle()) {
            FinishTurn();
        }
    }
    cJSON_Delete(msg);
}

void Voice::OnPlaybackDrained() {
    if (audio_ && phase_ == Phase::Speaking && server_done_) FinishTurn();
}

void Voice::Tick() {
    int64_t now = NowMs();
    if (discard_audio_ && now - discard_since_ms_ > kDiscardExpiryMs) discard_audio_ = false;
    if (hide_overlay_at_ms_ && now >= hide_overlay_at_ms_ && phase_ == Phase::Idle) {
        GoIdle();
        return;
    }
    if ((phase_ == Phase::Thinking || phase_ == Phase::Speaking) && now - last_server_ms_ > kReplyWatchdogMs) {
        FailTurn("Jarvis took too long to answer");
        return;
    }
    if (phase_ == Phase::Listening) {
        if (speech_seen_ && silence_since_ms_ && now - silence_since_ms_ >= kEndSilenceMs) {
            EndTurn();
        } else if (!speech_seen_ && now - last_heard_ms_ >= kListenCapMs) {
            ESP_LOGI(TAG, "turn: nothing said for 2 minutes, going idle");
            GoIdle();
        } else if (now - turn_start_ms_ >= kMaxTurnMs) {
            EndTurn();
        }
    } else if (phase_ == Phase::Idle && ws_ && last_turn_end_ms_ && now - last_turn_end_ms_ >= kSocketIdleMs) {
        CloseSocket();
    }
}

}  // namespace jarvis
