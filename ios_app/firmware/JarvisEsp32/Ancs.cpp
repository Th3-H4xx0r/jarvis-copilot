#include "Ancs.h"

#include <BLEDevice.h>
#include <esp_gatt_defs.h>

namespace jarvis {
namespace {

// Any app id no BLEClient uses; the board creates none.
constexpr uint16_t gattc_app_id = 0x4A43;
// Discovery is retried this often until subscribed (the user may allow notifications late).
constexpr uint32_t rediscover_ms = 15000;
// iOS answers a Get Notification Attributes in milliseconds; past this it never will.
constexpr uint32_t request_timeout_ms = 3000;
constexpr uint8_t queue_depth = 8;  // also covers the seconds a reconnecting phone takes to re-auth

AncsClient* g_self = nullptr;

void on_gattc(esp_gattc_cb_event_t event, esp_gatt_if_t gattc_if, esp_ble_gattc_cb_param_t* param) {
  if (g_self != nullptr) g_self->handle(event, gattc_if, param);
}

esp_bt_uuid_t uuid128(const char* s) {
  esp_bt_uuid_t u = {};
  u.len = ESP_UUID_LEN_128;
  ancs::uuid128_le(s, u.uuid.uuid128);
  return u;
}

}  // namespace

void AncsClient::begin() {
  queue_ = xQueueCreate(queue_depth, sizeof(AncsNotification));
  if (queue_ == nullptr) { Serial.println("[ancs] no memory for the queue, relay off"); return; }
  g_self = this;
  enabled_ = true;
  BLEDevice::setCustomGattcHandler(on_gattc);
  esp_ble_gattc_app_register(gattc_app_id);
  Serial.println("[ancs] relay on, waiting for the phone");
}

AncsState AncsClient::state() const {
  if (!enabled_) return AncsState::off;
  if (phase_ == Phase::receiving) return AncsState::receiving;
  if (phase_ == Phase::not_shared) return AncsState::not_shared;
  return AncsState::waiting;
}

bool AncsClient::take(AncsNotification& out) {
  if (queue_ == nullptr || xQueueReceive(queue_, &out, 0) != pdTRUE) return false;
  forwarded_ = forwarded_ + 1;
  return true;
}

void AncsClient::service(uint32_t now) {
  if (!enabled_ || !open_ || !encrypted_ || phase_ == Phase::receiving) return;
  if (static_cast<int32_t>(now - retry_at_ms_) < 0) return;
  // Either the first try on this link, or the last one stalled or found no ANCS.
  phase_ = Phase::discovering;
  retry_at_ms_ = now + rediscover_ms;
  start_ = end_ = 0;
  esp_bt_uuid_t service = uuid128(ancs::service_uuid);
  esp_ble_gattc_search_service(if_, conn_id_, &service);
}

// Bluedroid keeps notify registrations per app and peer (5 slots), and the iPhone's
// address rotates, so stale ones are dropped whenever the handles go away.
void AncsClient::drop_registrations() {
  if (ns_ != 0) esp_ble_gattc_unregister_for_notify(if_, bda_, ns_);
  if (ds_ != 0) esp_ble_gattc_unregister_for_notify(if_, bda_, ds_);
  ns_ = cp_ = ds_ = 0;
}

void AncsClient::reset_link() {
  open_ = false;
  encrypted_ = false;
  phase_ = Phase::idle;
  retry_at_ms_ = 0;
  drop_registrations();
  count_ = 0;
  outstanding_ = false;
}

void AncsClient::not_shared(const char* why, int status) {
  phase_ = Phase::not_shared;
  Serial.printf("[ancs] %s (0x%02x); retrying in %lus\n", why, status,
                static_cast<unsigned long>(rediscover_ms / 1000));
}

void AncsClient::handle(esp_gattc_cb_event_t event, esp_gatt_if_t gattc_if, esp_ble_gattc_cb_param_t* p) {
  if (event == ESP_GATTC_REG_EVT) {
    if (p->reg.app_id == gattc_app_id && p->reg.status == ESP_GATT_OK) if_ = gattc_if;
    return;
  }
  if (if_ == ESP_GATT_IF_NONE || gattc_if != if_) return;

  switch (event) {
    case ESP_GATTC_CONNECT_EVT:
      // The phone connected to our server. Open a client on that same link — no new
      // connection is made; Bluedroid just gives this app a handle on it.
      memcpy(bda_, p->connect.remote_bda, sizeof(bda_));
      esp_ble_gattc_open(if_, bda_, p->connect.ble_addr_type, true);
      break;
    case ESP_GATTC_OPEN_EVT:
      if (p->open.status != ESP_GATT_OK) {
        Serial.printf("[ancs] client open failed (0x%02x)\n", p->open.status);
        break;
      }
      conn_id_ = p->open.conn_id;
      phase_ = Phase::idle;
      retry_at_ms_ = millis();
      open_ = true;  // service() discovers once the link is also encrypted
      break;
    case ESP_GATTC_DISCONNECT_EVT:
      reset_link();
      break;
    case ESP_GATTC_SEARCH_RES_EVT:
      start_ = p->search_res.start_handle;
      end_ = p->search_res.end_handle;
      break;
    case ESP_GATTC_SEARCH_CMPL_EVT:
      if (p->search_cmpl.status != ESP_GATT_OK) { not_shared("discovery failed", p->search_cmpl.status); break; }
      subscribe();
      break;
    case ESP_GATTC_REG_FOR_NOTIFY_EVT:
      if (p->reg_for_notify.status != ESP_GATT_OK) { not_shared("notify registration failed", p->reg_for_notify.status); break; }
      enable_cccd(p->reg_for_notify.handle);
      break;
    case ESP_GATTC_WRITE_DESCR_EVT:
      if (phase_ != Phase::subscribing) break;
      Serial.printf("[ancs] subscribe write handle=%u status=0x%02x\n", p->write.handle, p->write.status);
      if (p->write.status != ESP_GATT_OK) { not_shared("phone refused the subscription", p->write.status); break; }
      if (++cccd_done_ == 2) {
        phase_ = Phase::receiving;
        Serial.println("[ancs] receiving iPhone notifications");
      }
      break;
    case ESP_GATTC_WRITE_CHAR_EVT:
      // A refused request means the notification was gone before we asked; move on.
      if (p->write.handle == cp_) Serial.printf("[ancs] request written status=0x%02x\n", p->write.status);
      if (p->write.handle == cp_ && p->write.status != ESP_GATT_OK) {
        outstanding_ = false;
        request_next();
      }
      break;
    case ESP_GATTC_NOTIFY_EVT:
      if (p->notify.handle == ns_) on_source(p->notify.value, p->notify.value_len);
      else if (p->notify.handle == ds_) on_data(p->notify.value, p->notify.value_len);
      break;
    case ESP_GATTC_SRVC_CHG_EVT:
      // The phone's GATT database changed (ANCS can appear once notifications are
      // allowed): forget the handles and let service() rediscover now.
      esp_ble_gattc_cache_refresh(bda_);
      drop_registrations();
      phase_ = Phase::idle;
      retry_at_ms_ = millis() + 1000;
      break;
    default:
      break;
  }
}

uint16_t AncsClient::char_handle(const char* uuid) {
  esp_gattc_char_elem_t el = {};
  uint16_t count = 1;
  if (esp_ble_gattc_get_char_by_uuid(if_, conn_id_, start_, end_, uuid128(uuid), &el, &count) != ESP_GATT_OK || count == 0) return 0;
  return el.char_handle;
}

void AncsClient::subscribe() {
  drop_registrations();  // a retry re-registers from scratch
  if (start_ == 0) { not_shared("phone offers no ANCS", 0); return; }
  ns_ = char_handle(ancs::notification_source_uuid);
  cp_ = char_handle(ancs::control_point_uuid);
  ds_ = char_handle(ancs::data_source_uuid);
  Serial.printf("[ancs] handles source=%u control=%u data=%u\n", ns_, cp_, ds_);
  if (ns_ == 0 || cp_ == 0 || ds_ == 0) { not_shared("ANCS characteristics missing", 0); return; }
  phase_ = Phase::subscribing;
  cccd_done_ = 0;
  count_ = 0;
  outstanding_ = false;
  // Data Source first, as Apple asks, so no attribute reply can beat its subscription.
  esp_ble_gattc_register_for_notify(if_, bda_, ds_);
  esp_ble_gattc_register_for_notify(if_, bda_, ns_);
}

void AncsClient::enable_cccd(uint16_t char_handle) {
  esp_bt_uuid_t cccd = {};
  cccd.len = ESP_UUID_LEN_16;
  cccd.uuid.uuid16 = ESP_GATT_UUID_CHAR_CLIENT_CONFIG;
  esp_gattc_descr_elem_t d = {};
  uint16_t count = 1;
  if (esp_ble_gattc_get_descr_by_char_handle(if_, conn_id_, char_handle, cccd, &d, &count) != ESP_GATT_OK || count == 0) {
    not_shared("ANCS subscription descriptor missing", 0);
    return;
  }
  uint8_t on[2] = {0x01, 0x00};
  esp_ble_gattc_write_char_descr(if_, conn_id_, d.handle, sizeof(on), on, ESP_GATT_WRITE_TYPE_RSP, ESP_GATT_AUTH_REQ_NONE);
}

void AncsClient::on_source(const uint8_t* v, size_t n) {
  ancs::SourceEvent e;
  if (!ancs::parse_source(v, n, e)) return;
  Serial.printf("[ancs] source event=%u flags=0x%02x category=%u uid=%lu%s\n", e.event_id, e.flags, e.category,
                static_cast<unsigned long>(e.uid), ancs::wants(e) ? "" : " (skipped)");
  if (!ancs::wants(e)) return;
  if (count_ < pending_cap) {  // a burst bigger than the backlog drops the newest
    pending_[(head_ + count_) % pending_cap] = Pending{e.uid, e.category};
    ++count_;
  }
  if (outstanding_ && millis() - sent_at_ms_ > request_timeout_ms) outstanding_ = false;  // never answered
  request_next();
}

void AncsClient::request_next() {
  while (!outstanding_ && count_ > 0) {
    const Pending next = pending_[head_];
    head_ = (head_ + 1) % pending_cap;
    --count_;
    uint8_t req[ancs::request_len];
    const size_t n = ancs::build_request(next.uid, req);
    assembler_.begin(next.uid);
    outstanding_category_ = next.category;
    const esp_err_t err = esp_ble_gattc_write_char(if_, conn_id_, cp_, n, req, ESP_GATT_WRITE_TYPE_RSP, ESP_GATT_AUTH_REQ_NONE);
    Serial.printf("[ancs] asking for uid=%lu (err=%d)\n", static_cast<unsigned long>(next.uid), err);
    if (err == ESP_OK) {
      outstanding_ = true;
      sent_at_ms_ = millis();
    }
  }
}

void AncsClient::on_data(const uint8_t* v, size_t n) {
  if (!outstanding_) return;
  switch (assembler_.feed(v, n)) {
    case ancs::Assembler::Result::more:
      return;
    case ancs::Assembler::Result::done:
      Serial.printf("[ancs] got cat=%u app=%s title=%uB message=%uB\n", outstanding_category_, assembler_.attributes().app,
                    static_cast<unsigned>(strlen(assembler_.attributes().title)),
                    static_cast<unsigned>(strlen(assembler_.attributes().message)));
      scratch_.category = outstanding_category_;
      scratch_.attrs = assembler_.attributes();
      // loop() is behind: drop rather than block the Bluetooth task.
      if (xQueueSend(queue_, &scratch_, 0) != pdTRUE) Serial.println("[ancs] queue full, notification dropped");
      break;
    case ancs::Assembler::Result::error:
      Serial.println("[ancs] unreadable attribute reply, skipped");
      break;
  }
  outstanding_ = false;
  request_next();
}

}  // namespace jarvis
