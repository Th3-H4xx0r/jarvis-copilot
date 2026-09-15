// What the board found at boot, set by the board file before Application starts.
#pragma once

#include <functional>

namespace jarvis {

struct BoardCaps {
    bool codec_present = false;   // ES8311 answered on I2C: this is the supported revision
    bool touch_present = false;   // CST816D answered: on-screen controls work
    std::function<bool(int& x, int& y)> read_touch;  // unused by the app; the board pushes taps
};

inline BoardCaps& Caps() {
    static BoardCaps caps;
    return caps;
}

}  // namespace jarvis
