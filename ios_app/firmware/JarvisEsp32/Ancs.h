// iPhone notifications over ANCS, for the glasses relay. The phone connects to the board
// as usual; once that link is encrypted the board also acts as a GATT client on the same
// link, subscribes to the phone's Apple Notification Center Service and fetches each new
// notification's app, title and message. loop() takes them with take() and forwards them
// to the owner as `ios_notification` events; the app puts them on the glasses.
//
// iOS only shares ANCS with a bonded accessory the user allowed, so the relay switch
// also turns bonding on (setup_ble()), and the app connects with RequiresANCS.
//
// Threading: GATT callbacks and the request pipeline run on the Bluetooth task; finished
// notifications reach loop() through a FreeRTOS queue. service() (loop) only starts
// discovery, through the thread-safe esp_ble_gattc_* calls.
#ifndef JARVIS_ESP32_ANCS_H
#define JARVIS_ESP32_ANCS_H

#include <Arduino.h>
#include <esp_gattc_api.h>

#include "AncsParser.h"

namespace jarvis {

enum class AncsState : uint8_t {
  off        = 0,  // relay switched off
  waiting    = 1,  // relay on, no encrypted phone link yet (or still subscribing)
  receiving  = 2,  // subscribed to the phone's notifications
  not_shared = 3,  // the phone didn't offer ANCS: not bonded, or notifications not allowed
};

struct AncsNotification {
  uint8_t category;  // ANCS CategoryID (1 = incoming call, 4 = social, …)
  ancs::Attributes attrs;
};

class AncsClient {
 public:
  /// Registers the GATT client. Call after BLEDevice::init, only when the relay is on.
  void begin();
  /// The phone's link finished pairing and is encrypted (Bluetooth task).
  void on_encrypted() { encrypted_ = true; }
  /// loop(): (re)starts discovery while ANCS isn't subscribed yet.
  void service(uint32_t now);
  /// loop(): next finished notification, if any. Call only with an owner session to
  /// hand it to: until then notifications wait in the queue (newest dropped when full).
  bool take(AncsNotification& out);

  AncsState state() const;
  uint16_t forwarded() const { return forwarded_; }

  void handle(esp_gattc_cb_event_t event, esp_gatt_if_t gattc_if, esp_ble_gattc_cb_param_t* param);

 private:
  enum class Phase : uint8_t { idle, discovering, subscribing, receiving, not_shared };
  struct Pending { uint32_t uid; uint8_t category; };

  void reset_link();
  void drop_registrations();
  void subscribe();
  uint16_t char_handle(const char* uuid);
  void enable_cccd(uint16_t char_handle);
  void not_shared(const char* why, int status);
  void on_source(const uint8_t* v, size_t n);
  void on_data(const uint8_t* v, size_t n);
  void request_next();

  QueueHandle_t queue_ = nullptr;
  bool enabled_ = false;
  volatile esp_gatt_if_t if_ = ESP_GATT_IF_NONE;
  volatile bool open_ = false;
  volatile bool encrypted_ = false;
  volatile Phase phase_ = Phase::idle;
  volatile uint32_t retry_at_ms_ = 0;
  volatile uint16_t forwarded_ = 0;
  uint16_t conn_id_ = 0;
  esp_bd_addr_t bda_ = {};
  uint16_t start_ = 0, end_ = 0;
  uint16_t ns_ = 0, cp_ = 0, ds_ = 0;
  uint8_t cccd_done_ = 0;

  // Request pipeline: one Get Notification Attributes in flight at a time, because
  // Data Source replies are not tagged by request. Bluetooth task only.
  static constexpr uint8_t pending_cap = 16;
  Pending pending_[pending_cap] = {};
  uint8_t head_ = 0, count_ = 0;
  bool outstanding_ = false;
  uint8_t outstanding_category_ = 0;
  uint32_t sent_at_ms_ = 0;
  ancs::Assembler assembler_;
  AncsNotification scratch_ = {};  // off the Bluetooth task's small stack
};

}  // namespace jarvis

#endif  // JARVIS_ESP32_ANCS_H
