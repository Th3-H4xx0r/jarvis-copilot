#ifndef MICRO_WAKE_WORD_H
#define MICRO_WAKE_WORD_H

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>

// JARVIS: "Hey Jarvis" with microWakeWord — Kevin Ahrendt's v2 model (Apache-2.0,
// github.com/esphome/micro-wake-word-models), trained on real speech, where the WakeNet
// "Jarvis" model was trained on TTS and caught about one wake word in eight.
//
// A streaming TensorFlow Lite Micro model reads 40 log-mel features every 10 ms (the TFLM
// micro frontend, set up as microWakeWord trains it); a detection is the mean of its last
// few outputs passing the model's cutoff. One task feeds it; it is not thread-safe.
class MicroWakeWord {
public:
    MicroWakeWord();
    ~MicroWakeWord();

    // Loads the embedded model and proves it runs. False leaves nothing allocated.
    bool Initialize();
    // 16 kHz mono. True when the wake word was just heard.
    bool Feed(const int16_t* samples, size_t count);
    // Forget everything heard so far, for a new listening session.
    void Reset();

    const std::string& wake_word() const { return wake_word_; }

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
    std::string wake_word_ = "Hey Jarvis";

    bool AddFeatures(const uint16_t* values);
    void Release();
};

#endif
