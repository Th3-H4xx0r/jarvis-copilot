#include "micro_wake_word.h"

#include <array>
#include <cmath>
#include <cstring>

#include <esp_heap_caps.h>
#include <esp_log.h>
#include <esp_timer.h>
#include <frontend.h>
#include <frontend_util.h>

#include "tensorflow/lite/micro/micro_allocator.h"
#include "tensorflow/lite/micro/micro_interpreter.h"
#include "tensorflow/lite/micro/micro_mutable_op_resolver.h"
#include "tensorflow/lite/micro/micro_resource_variable.h"
#include "tensorflow/lite/schema/schema_generated.h"

#define TAG "MicroWakeWord"

extern const uint8_t hey_jarvis_tflite_start[] asm("_binary_hey_jarvis_tflite_start");
extern const uint8_t hey_jarvis_tflite_end[] asm("_binary_hey_jarvis_tflite_end");

namespace {

// From the model's manifest (models/v2/hey_jarvis.json).
constexpr float kProbabilityCutoff = 0.97f;
constexpr size_t kSlidingWindow = 5;
constexpr size_t kTensorArenaSize = 22860 + 1024;  // the manifest's size, plus headroom

// The features microWakeWord trains on: the TFLM micro frontend at 30 ms windows every
// 10 ms, 40 channels between 125 Hz and 7.5 kHz, with PCAN gain control.
constexpr int kSampleRate = 16000;
constexpr int kFeatureCount = 40;
constexpr int kFeatureWindowMs = 30;
constexpr int kFeatureStepMs = 10;
// The frontend's 16-bit features become the model's float inputs divided by 25.6
// (the TFLM micro_speech convention the features were trained with).
constexpr float kFeatureToFloat = 1.0f / 25.6f;

// The model streams: its VAR_HANDLE state lives in its own small arena.
constexpr size_t kVariableArenaSize = 2048;
constexpr int kMaxResourceVariables = 20;
// A detection before the model has heard a second of audio is on a half-empty state.
constexpr int kWarmupFeatures = 1000 / kFeatureStepMs;
// Log a near miss at most this often, so a threshold can be judged from the logs.
constexpr int64_t kNearMissLogEveryUs = 2 * 1000 * 1000;
constexpr float kNearMissFloor = 0.5f;

constexpr int kOpCount = 12;

}  // namespace

struct MicroWakeWord::Impl {
    tflite::MicroMutableOpResolver<kOpCount> resolver;
    uint8_t* model_copy = nullptr;
    uint8_t* tensor_arena = nullptr;
    uint8_t* variable_arena = nullptr;
    tflite::MicroResourceVariables* variables = nullptr;  // lives in variable_arena
    std::unique_ptr<tflite::MicroInterpreter> interpreter;
    TfLiteTensor* input = nullptr;

    FrontendState frontend = {};
    bool frontend_ready = false;

    int stride = 1;  // feature rows per inference
    int filled = 0;  // rows written into the current input
    float feature_to_input = 0.0f;
    int input_zero_point = 0;

    std::array<float, kSlidingWindow> recent = {};
    size_t next = 0;
    int warmup = kWarmupFeatures;

    int64_t last_near_miss_log_us = 0;
    int64_t invoke_us_total = 0;
    int invokes_timed = 0;
};

MicroWakeWord::MicroWakeWord() : impl_(std::make_unique<Impl>()) {}

MicroWakeWord::~MicroWakeWord() { Release(); }

void MicroWakeWord::Release() {
    auto& m = *impl_;
    m.interpreter.reset();
    m.input = nullptr;
    m.variables = nullptr;
    if (m.frontend_ready) {
        FrontendFreeStateContents(&m.frontend);
        m.frontend_ready = false;
    }
    heap_caps_free(m.variable_arena);
    heap_caps_free(m.tensor_arena);
    heap_caps_free(m.model_copy);
    m.variable_arena = m.tensor_arena = m.model_copy = nullptr;
}

bool MicroWakeWord::Initialize() {
    auto& m = *impl_;
    const uint8_t* model_data = hey_jarvis_tflite_start;
    const size_t model_size = hey_jarvis_tflite_end - hey_jarvis_tflite_start;
    // The flatbuffer's tensor data must be 16-byte aligned; embedded files only promise 4.
    if (reinterpret_cast<uintptr_t>(model_data) % 16 != 0) {
        m.model_copy = static_cast<uint8_t*>(heap_caps_aligned_alloc(16, model_size, MALLOC_CAP_SPIRAM));
        if (m.model_copy == nullptr) {
            ESP_LOGE(TAG, "No memory for the model (%u bytes)", static_cast<unsigned>(model_size));
            return false;
        }
        memcpy(m.model_copy, model_data, model_size);
        model_data = m.model_copy;
    }
    const tflite::Model* model = tflite::GetModel(model_data);
    if (model->version() != TFLITE_SCHEMA_VERSION) {
        ESP_LOGE(TAG, "Model schema %lu, expected %d", static_cast<unsigned long>(model->version()),
                 TFLITE_SCHEMA_VERSION);
        Release();
        return false;
    }

    // Exactly the operators the model uses (read from its operator codes).
    const bool ops_ok = m.resolver.AddCallOnce() == kTfLiteOk && m.resolver.AddVarHandle() == kTfLiteOk &&
                        m.resolver.AddReshape() == kTfLiteOk && m.resolver.AddReadVariable() == kTfLiteOk &&
                        m.resolver.AddConcatenation() == kTfLiteOk && m.resolver.AddStridedSlice() == kTfLiteOk &&
                        m.resolver.AddAssignVariable() == kTfLiteOk && m.resolver.AddConv2D() == kTfLiteOk &&
                        m.resolver.AddDepthwiseConv2D() == kTfLiteOk && m.resolver.AddFullyConnected() == kTfLiteOk &&
                        m.resolver.AddLogistic() == kTfLiteOk && m.resolver.AddQuantize() == kTfLiteOk;
    if (!ops_ok) {
        ESP_LOGE(TAG, "Could not register the model's operators");
        Release();
        return false;
    }

    m.tensor_arena = static_cast<uint8_t*>(heap_caps_aligned_alloc(16, kTensorArenaSize, MALLOC_CAP_SPIRAM));
    m.variable_arena = static_cast<uint8_t*>(heap_caps_aligned_alloc(16, kVariableArenaSize, MALLOC_CAP_SPIRAM));
    if (m.tensor_arena == nullptr || m.variable_arena == nullptr) {
        ESP_LOGE(TAG, "No memory for the arenas");
        Release();
        return false;
    }
    tflite::MicroAllocator* variable_allocator = tflite::MicroAllocator::Create(m.variable_arena, kVariableArenaSize);
    m.variables = variable_allocator == nullptr
                      ? nullptr
                      : tflite::MicroResourceVariables::Create(variable_allocator, kMaxResourceVariables);
    if (m.variables == nullptr) {
        ESP_LOGE(TAG, "Could not set up the model's streaming state");
        Release();
        return false;
    }
    m.interpreter = std::make_unique<tflite::MicroInterpreter>(model, m.resolver, m.tensor_arena, kTensorArenaSize,
                                                               m.variables);
    if (m.interpreter->AllocateTensors() != kTfLiteOk) {
        ESP_LOGE(TAG, "Could not allocate the model's tensors");
        Release();
        return false;
    }

    m.input = m.interpreter->input(0);
    TfLiteTensor* output = m.interpreter->output(0);
    if (m.input == nullptr || m.input->type != kTfLiteInt8 || m.input->dims->size != 3 ||
        m.input->dims->data[2] != kFeatureCount || output == nullptr ||
        (output->type != kTfLiteUInt8 && output->type != kTfLiteInt8)) {
        ESP_LOGE(TAG, "The model's input or output is not the shape microWakeWord uses");
        Release();
        return false;
    }
    m.stride = m.input->dims->data[1];
    m.feature_to_input = kFeatureToFloat / m.input->params.scale;
    m.input_zero_point = m.input->params.zero_point;

    FrontendConfig config;
    FrontendFillConfigWithDefaults(&config);
    config.window.size_ms = kFeatureWindowMs;
    config.window.step_size_ms = kFeatureStepMs;
    config.filterbank.num_channels = kFeatureCount;
    config.filterbank.lower_band_limit = 125.0f;
    config.filterbank.upper_band_limit = 7500.0f;
    config.noise_reduction.smoothing_bits = 10;
    config.noise_reduction.even_smoothing = 0.025f;
    config.noise_reduction.odd_smoothing = 0.06f;
    config.noise_reduction.min_signal_remaining = 0.05f;
    config.pcan_gain_control.enable_pcan = 1;
    config.pcan_gain_control.strength = 0.95f;
    config.pcan_gain_control.offset = 80.0f;
    config.pcan_gain_control.gain_bits = 21;
    config.log_scale.enable_log = 1;
    config.log_scale.scale_shift = 6;
    if (!FrontendPopulateState(&config, &m.frontend, kSampleRate)) {
        ESP_LOGE(TAG, "Could not set up the feature frontend");
        Release();
        return false;
    }
    m.frontend_ready = true;

    // One inference on silence proves the arenas are big enough now, while the engine
    // can still fall back to WakeNet, rather than at the first word.
    memset(m.input->data.int8, m.input_zero_point, m.input->bytes);
    if (m.interpreter->Invoke() != kTfLiteOk) {
        ESP_LOGE(TAG, "The model did not run");
        Release();
        return false;
    }
    Reset();
    ESP_LOGI(TAG, "\"%s\" ready: %u-byte model, %d rows per inference, arena %u/%u bytes, cutoff %.2f",
             wake_word_.c_str(), static_cast<unsigned>(model_size), m.stride,
             static_cast<unsigned>(m.interpreter->arena_used_bytes()), static_cast<unsigned>(kTensorArenaSize),
             kProbabilityCutoff);
    return true;
}

void MicroWakeWord::Reset() {
    auto& m = *impl_;
    if (!m.interpreter) {
        return;
    }
    FrontendReset(&m.frontend);
    m.interpreter->Reset();
    m.variables->ResetAll();  // Reset() leaves the streaming state alone
    m.recent.fill(0.0f);
    m.next = 0;
    m.filled = 0;
    m.warmup = kWarmupFeatures;
}

bool MicroWakeWord::Feed(const int16_t* samples, size_t count) {
    auto& m = *impl_;
    if (!m.interpreter) {
        return false;
    }
    bool heard = false;
    while (count > 0) {
        size_t read = 0;
        FrontendOutput out = FrontendProcessSamples(&m.frontend, samples, count, &read);
        samples += read;
        count -= read;
        if (out.values != nullptr && out.size == static_cast<size_t>(kFeatureCount) && AddFeatures(out.values)) {
            heard = true;  // Reset() inside; keep consuming this chunk on the fresh state
        }
        if (read == 0) {
            break;
        }
    }
    return heard;
}

bool MicroWakeWord::AddFeatures(const uint16_t* values) {
    auto& m = *impl_;
    int8_t* row = m.input->data.int8 + m.filled * kFeatureCount;
    for (int i = 0; i < kFeatureCount; ++i) {
        int32_t q = static_cast<int32_t>(lroundf(values[i] * m.feature_to_input)) + m.input_zero_point;
        row[i] = static_cast<int8_t>(q < -128 ? -128 : (q > 127 ? 127 : q));
    }
    if (m.warmup > 0) {
        --m.warmup;
    }
    if (++m.filled < m.stride) {
        return false;
    }
    m.filled = 0;

    const int64_t started = esp_timer_get_time();
    if (m.interpreter->Invoke() != kTfLiteOk) {
        ESP_LOGW(TAG, "Inference failed");
        return false;
    }
    if (m.invokes_timed < 100) {
        m.invoke_us_total += esp_timer_get_time() - started;
        if (++m.invokes_timed == 100) {
            ESP_LOGI(TAG, "Inference takes %lld us on average", m.invoke_us_total / 100);
        }
    }

    const TfLiteTensor* output = m.interpreter->output(0);
    const int32_t raw = output->type == kTfLiteUInt8 ? output->data.uint8[0] : output->data.int8[0];
    m.recent[m.next] = (raw - output->params.zero_point) * output->params.scale;
    m.next = (m.next + 1) % kSlidingWindow;
    if (m.warmup > 0) {
        return false;
    }

    float mean = 0.0f;
    for (float p : m.recent) {
        mean += p;
    }
    mean /= kSlidingWindow;
    if (mean <= kProbabilityCutoff) {
        const int64_t now = esp_timer_get_time();
        if (mean >= kNearMissFloor && now - m.last_near_miss_log_us > kNearMissLogEveryUs) {
            m.last_near_miss_log_us = now;
            ESP_LOGI(TAG, "wake: near miss %.2f (cutoff %.2f)", mean, kProbabilityCutoff);
        }
        return false;
    }
    ESP_LOGI(TAG, "wake: heard \"%s\" (%.2f)", wake_word_.c_str(), mean);
    Reset();  // one detection per utterance
    return true;
}
