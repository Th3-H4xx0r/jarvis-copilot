# Upstream

`jarvis_pod/` is [xiaozhi-esp32](https://github.com/78/xiaozhi-esp32) **v2.5.0**
(commit `ac6deed3d8e75348475364bf40ad953c6cd48054`, MIT) copied once and trimmed. It is not
a fork and does not track upstream; to take an upstream fix, diff the files below against
that tag by hand. Design: `docs/superpowers/specs/2026-09-14-jarvis-pod-design.md` (local).

Build: ESP-IDF v6.0.3 (`~/esp/esp-idf-v6.0.3`), `scripts/flash.sh`. Host tests: `scripts/test_host.sh`.

## Kept from upstream

xiaozhi is the hardware and audio platform: `main/boards/common/` (Wi-Fi board, backlight,
button, I2C, power-save timer, battery), `main/boards/spotpear/sp-esp32-s3-1.28-box/`,
`main/audio/` (AudioService: codec, AFE, WakeNet, Opus), `main/display/` (LVGL port; its
chat UI still builds and sits hidden under the Jarvis layer), `main/led/`, `main/assets/`
(fonts, language strings, sounds), `main/protocols/protocol.*` (the `AudioStreamPacket`
struct), `main/settings.*`, `main/system_info.*`, the build scripts and partitions.

## Removed

- `main/application.*`, `main/main.cc` — replaced by Jarvis files of the same names
  (same `Application` class name so kept upstream files compile unmodified).
- `main/mcp_server.*`, `main/ota.*`, `main/device_state_machine.*`,
  `main/protocols/{mqtt,websocket}_protocol.*`, `main/notify/` (not built).
- Every board except `spotpear/sp-esp32-s3-1.28-box`; `docs/`, `.github/`, non-S3 sdkconfig defaults.
- From the build only: `display/oled_display.cc`, `display/emote_display.cc`,
  `boards/common/{ml307,nt26,dual_network,axp2101,knob,press_to_talk_mcp_tool,sleep_timer,sy6970,esp_video,rndis,esp32_camera}`.

## Jarvis code

`main/jarvis/` — `logic/` (host-tested), `store/`, `link/` (claim, bridge, `pod_*` skills),
`setup/` (QR hotspot + HTTP API), `voice/` (shared voice session, Opus), `ui/` (pages,
menu, back, orb, clock), `board_caps.h`. `partitions/jarvis_16m.csv`, `scripts/`, `host_tests/`.

## Edits to kept upstream files (each marked `JARVIS`)

| File | Change |
|---|---|
| `main/CMakeLists.txt` | removed sources above; glob `jarvis/*.cc`; PRIV_REQUIRES esp_http_server, esp_wifi, spiffs, lwip; no camera/RNDIS |
| `main/idf_component.yml` | dropped `image_player`, `esp_emote_expression` (duplicate `qrcodegen` with LVGL) |
| `sdkconfig.defaults` | Jarvis partition table, board type, Montserrat fonts, QR code, chart, TJPGD; no app rollback |
| `sdkconfig.defaults.esp32s3` | wake word `wn9_jarvis_tts` instead of `nihaoxiaozhi` |
| `main/audio/codecs/es8311_audio_codec.cc` | mic input gain 30 → 42 dB (wake word at speaking volume) |
| `main/audio/engines/afe_audio_engine.cc` | `wakenet_mode = DET_MODE_95` |
| `partitions/jarvis_16m.csv` (new) | factory 3.5 MB, `orb` data 0x40 at 0x3A0000 (frames from `scripts/render_orb.sh`, written by `flash.sh`), pages, assets |
| `main/boards/common/wifi_board.cc` | hostname prefix `Jarvis`; no open config hotspot — `Application::OnWifiUnavailable()` and keep retrying |
| `main/boards/spotpear/sp-esp32-s3-1.28-box/sp-esp32-s3-1.28-box.cc` | codec/touch probes → `jarvis::Caps()`; BOOT single/double/long/5 s and taps → `Application`; no auto power-off |
