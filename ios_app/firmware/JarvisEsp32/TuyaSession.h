// One Tuya LAN connection, without the socket: bytes in (feed), bytes out (take_output),
// timers (tick). Pure C++, host-tested in tests/tuya_codec_test.cpp against tinytuya
// vectors. TuyaLocal owns the socket, the retries and the reporting.
//
//   3.3       connect → DP_QUERY → first reply that decrypts proves the key → ready
//   3.4/3.5   connect → SESS_KEY_NEG_START(nonce) → RESP(device nonce + HMAC of ours)
//             → FINISH(HMAC of theirs), derive the session key → ready → DP_QUERY
//
// Ready sessions heartbeat every 10 s and fail once the hub has said nothing for 30 s.
// A failure before ready says what went wrong, so the caller can tell a wrong key
// (key_rejected) from a wrong protocol version (wrong_framing / no_answer).
#ifndef JARVIS_ESP32_TUYA_SESSION_H
#define JARVIS_ESP32_TUYA_SESSION_H

#include <deque>
#include <string>

#include "TuyaCodec.h"

namespace jarvis::tuya {

class Session {
 public:
  enum class Phase : uint8_t { idle, negotiating, awaiting_first, ready, failed };
  enum class Failure : uint8_t {
    none,
    key_rejected,   // the hub answered, but under another key (HMAC / tag / decrypt failure)
    no_answer,      // nothing usable within answer_timeout_ms
    wrong_framing,  // the hub answered in another protocol version's framing
    went_silent,    // an established session stopped hearing from the hub
    protocol,       // malformed / oversized frames
  };
  struct Report {
    uint32_t cmd = 0;
    std::string json;
    bool query = false;  // answers a DP query (a snapshot), not an unsolicited push
  };
  using Rng = void (*)(uint8_t* out, size_t n);

  static constexpr uint32_t answer_timeout_ms = 5000;
  static constexpr uint32_t heartbeat_interval_ms = 10000;
  static constexpr uint32_t silent_after_ms = 30000;
  static constexpr size_t max_reports = 8;
  static constexpr size_t rx_limit = 4096;

  explicit Session(Rng rng) : rng_(rng) {}
  ~Session() { wipe_keys(); }
  Session(const Session&) = delete;
  Session& operator=(const Session&) = delete;

  /// Begins the handshake on a freshly connected socket; the first frame is queued.
  void start(Version v, const std::string& dev_id, const uint8_t local_key[16], uint32_t now_ms, uint32_t unix_s) {
    reset();
    version_ = v;
    dev_id_ = dev_id;
    memcpy(local_key_, local_key, 16);
    memcpy(key_, local_key, 16);
    seq_ = 1;
    now_ms_ = started_ms_ = last_rx_ms_ = last_hb_ms_ = now_ms;
    if (v == Version::v34 || v == Version::v35) {
      rng_(client_nonce_, 16);
      phase_ = Phase::negotiating;
      queue_frame(cmd::sess_key_neg_start, client_nonce_, 16);
    } else if (v == Version::v33) {
      phase_ = Phase::awaiting_first;
      send_query(unix_s);
    } else {
      fail(Failure::protocol, "no protocol version");
    }
  }

  /// Back to idle; key material wiped.
  void reset() {
    wipe_keys();
    phase_ = Phase::idle;
    failure_ = Failure::none;
    detail_.clear();
    rx_.clear();
    out_.clear();
    reports_.clear();
    device22_ = false;
    hb_pending_ = false;
    rtt_ms_ = -1;
    dropped_ = 0;
    acks_ = 0;
    query_open_ = false;
    query_acked_ = false;
  }

  void feed(const uint8_t* data, size_t len, uint32_t now_ms, uint32_t unix_s) {
    if (phase_ == Phase::idle || phase_ == Phase::failed || len == 0) return;
    now_ms_ = now_ms;
    last_rx_ms_ = now_ms;
    rx_.insert(rx_.end(), data, data + len);
    while (phase_ != Phase::failed && rx_.size() >= 4) {
      const size_t off = find_prefix(rx_.data(), rx_.size());
      if (off > 0) { rx_.erase(rx_.begin(), rx_.begin() + static_cast<long>(off)); continue; }
      uint32_t prefix = 0;
      size_t total = 0;
      const Unpack h = frame_size(rx_.data(), rx_.size(), prefix, total);
      if (h == Unpack::need_more) break;
      if (h == Unpack::too_large) { fail(Failure::protocol, "frame header claims an oversized payload"); return; }
      if (h != Unpack::ok) { rx_.erase(rx_.begin()); continue; }
      if (rx_.size() < total) break;
      handle_frame(rx_.data(), total, prefix, now_ms, unix_s);
      if (phase_ == Phase::failed) return;
      rx_.erase(rx_.begin(), rx_.begin() + static_cast<long>(total));
    }
    if (rx_.size() > rx_limit) fail(Failure::protocol, "receive buffer overflow");
  }

  void tick(uint32_t now_ms, uint32_t unix_s) {
    (void)unix_s;
    now_ms_ = now_ms;
    if (phase_ == Phase::negotiating || phase_ == Phase::awaiting_first) {
      if (now_ms - started_ms_ > answer_timeout_ms) {
        fail(Failure::no_answer, phase_ == Phase::negotiating ? "no answer to the key negotiation"
                                                               : "no answer to the status query");
      }
      return;
    }
    if (phase_ != Phase::ready) return;
    if (now_ms - last_rx_ms_ > silent_after_ms) { fail(Failure::went_silent, "hub silent for 30 s"); return; }
    if (now_ms - last_hb_ms_ >= heartbeat_interval_ms) {
      last_hb_ms_ = now_ms;
      queue_frame(cmd::heart_beat, heartbeat_json(dev_id_));
      hb_pending_ = true;
      hb_sent_ms_ = now_ms;
    }
  }

  /// Writes data points; `dps_json` is a JSON object. False unless the session is ready.
  bool control(const std::string& dps_json, uint32_t unix_s) {
    if (phase_ != Phase::ready) return false;
    queue_frame(control_cmd(version_), control_json(version_, dev_id_, dps_json, unix_s));
    return true;
  }

  /// Asks for every data point. The answer arrives as a report with `query` set.
  bool query(uint32_t unix_s) {
    if (phase_ != Phase::ready) return false;
    send_query(unix_s);
    return true;
  }

  /// Moves everything queued for the socket into `out` (appended).
  bool take_output(Bytes& out) {
    if (out_.empty()) return false;
    out.insert(out.end(), out_.begin(), out_.end());
    out_.clear();
    return true;
  }

  bool take_report(Report& r) {
    if (reports_.empty()) return false;
    r = std::move(reports_.front());
    reports_.pop_front();
    return true;
  }

  Phase phase() const { return phase_; }
  Failure failure() const { return failure_; }
  const std::string& detail() const { return detail_; }
  bool ready() const { return phase_ == Phase::ready; }
  Version version() const { return version_; }
  int32_t rtt_ms() const { return rtt_ms_; }
  uint32_t dropped_frames() const { return dropped_; }
  uint32_t query_acks() const { return acks_; }
  bool device22() const { return device22_; }
  /// The key frames are currently protected with (the session key once ready). Tests only.
  const uint8_t* session_key() const { return key_; }

 private:
  void wipe_keys() {
    secure_zero(local_key_, sizeof(local_key_));
    secure_zero(key_, sizeof(key_));
    secure_zero(client_nonce_, sizeof(client_nonce_));
  }

  void fail(Failure f, const char* why) {
    phase_ = Phase::failed;
    failure_ = f;
    detail_ = why;
    out_.clear();
  }

  void queue_frame(uint32_t command, const uint8_t* payload, size_t len) {
    uint8_t iv[12];
    if (version_ == Version::v35) rng_(iv, sizeof(iv));
    const Bytes frame = encode_message(version_, key_, seq_++, command, payload, len,
                                       version_ == Version::v35 ? iv : nullptr);
    out_.insert(out_.end(), frame.begin(), frame.end());
  }
  void queue_frame(uint32_t command, const std::string& payload) {
    queue_frame(command, reinterpret_cast<const uint8_t*>(payload.data()), payload.size());
  }

  void send_query(uint32_t unix_s) {
    queue_frame(query_cmd(version_, device22_), query_json(version_, dev_id_, unix_s, device22_));
    query_open_ = true;
    query_acked_ = false;
    query_sent_ms_ = now_ms_;
  }

  bool query_window_open(uint32_t now_ms) const {
    return query_open_ && now_ms - query_sent_ms_ <= answer_timeout_ms;
  }

  bool is_query_reply_cmd(uint32_t c) const {
    return c == cmd::dp_query || c == cmd::dp_query_new || (device22_ && c == cmd::control_new);
  }

  void push_report(uint32_t command, std::string&& json, uint32_t now_ms) {
    Report r;
    r.cmd = command;
    r.json = std::move(json);
    // Direct replies to the query command, or the STATUS a hub sends right after an
    // empty query ack while the query is still open.
    if (is_query_reply_cmd(command) ||
        (command == cmd::status && query_acked_ && query_window_open(now_ms))) {
      r.query = true;
      query_open_ = false;
      query_acked_ = false;
    }
    reports_.push_back(std::move(r));
    while (reports_.size() > max_reports) reports_.pop_front();
  }

  void handle_frame(const uint8_t* buf, size_t total, uint32_t prefix, uint32_t now_ms, uint32_t unix_s) {
    const bool established = phase_ == Phase::ready;
    const uint32_t expected = version_ == Version::v35 ? prefix_6699 : prefix_55aa;
    if (prefix != expected) {
      if (established) { ++dropped_; return; }
      fail(Failure::wrong_framing, version_ == Version::v35 ? "hub answered with 55AA framing (not 3.5)"
                                                            : "hub answered with 6699 framing (3.5)");
      return;
    }
    Frame f;
    size_t used = 0;
    const Unpack u = unpack(buf, total, key_, version_ == Version::v34, f, used);
    if (u != Unpack::ok) {
      if (established) { ++dropped_; return; }
      if (u == Unpack::bad_check) {
        if (version_ == Version::v33) {
          fail(Failure::wrong_framing, "CRC mismatch (hub speaks 3.4?)");
        } else if (version_ == Version::v34 && crc32_trailer_valid(buf, total)) {
          fail(Failure::wrong_framing, "hub answered with a CRC trailer (3.3?)");
        } else {
          fail(Failure::key_rejected, version_ == Version::v35 ? "GCM tag mismatch: local key looks wrong"
                                                               : "HMAC mismatch: local key looks wrong");
        }
      } else {
        fail(Failure::wrong_framing, "malformed frame");
      }
      return;
    }

    if (phase_ == Phase::negotiating) {
      if (f.cmd != cmd::sess_key_neg_resp) return;
      finish_negotiation(f.payload, now_ms, unix_s);
      return;
    }

    if (f.cmd == cmd::heart_beat && hb_pending_) {
      rtt_ms_ = static_cast<int32_t>(now_ms - hb_sent_ms_);
      hb_pending_ = false;
    }
    std::string json;
    switch (decode_payload(version_, key_, f.payload, json)) {
      case Decoded::bad:
        if (phase_ == Phase::awaiting_first) { fail(Failure::key_rejected, "reply does not decrypt with the local key"); return; }
        ++dropped_;
        return;
      case Decoded::unvalid:
        if (phase_ == Phase::awaiting_first) phase_ = Phase::ready;
        if (!device22_) { device22_ = true; send_query(unix_s); }
        return;
      case Decoded::empty:
        if (is_query_reply_cmd(f.cmd) && query_window_open(now_ms)) { ++acks_; query_acked_ = true; }
        return;
      case Decoded::json:
        if (phase_ == Phase::awaiting_first) phase_ = Phase::ready;
        push_report(f.cmd, std::move(json), now_ms);
        return;
    }
  }

  void finish_negotiation(const Bytes& payload, uint32_t now_ms, uint32_t unix_s) {
    (void)now_ms;
    Bytes p;
    if (version_ == Version::v34) {
      if (!ecb_decrypt_unpad(local_key_, payload.data(), payload.size(), p)) {
        fail(Failure::key_rejected, "key negotiation reply does not decrypt");
        return;
      }
    } else {
      p = payload;
    }
    if (p.size() < 48) { fail(Failure::protocol, "key negotiation reply too short"); return; }
    uint8_t expect[32];
    hmac_sha256(local_key_, 16, client_nonce_, 16, expect);
    if (!equal_ct(expect, p.data() + 16, 32)) {
      fail(Failure::key_rejected, "hub's nonce proof does not match the local key");
      return;
    }
    uint8_t remote[16];
    memcpy(remote, p.data(), 16);
    uint8_t proof[32];
    hmac_sha256(local_key_, 16, remote, 16, proof);
    queue_frame(cmd::sess_key_neg_finish, proof, sizeof(proof));  // still under the local key
    derive_session_key(version_, local_key_, client_nonce_, remote, key_);
    secure_zero(remote, sizeof(remote));
    phase_ = Phase::ready;
    send_query(unix_s);
  }

  Rng rng_;
  Version version_ = Version::unknown;
  std::string dev_id_;
  uint8_t local_key_[16] = {};
  uint8_t key_[16] = {};
  uint8_t client_nonce_[16] = {};
  uint32_t seq_ = 1;

  Phase phase_ = Phase::idle;
  Failure failure_ = Failure::none;
  std::string detail_;

  Bytes rx_;
  Bytes out_;
  std::deque<Report> reports_;

  uint32_t now_ms_ = 0;
  uint32_t started_ms_ = 0;
  uint32_t last_rx_ms_ = 0;
  uint32_t last_hb_ms_ = 0;
  uint32_t hb_sent_ms_ = 0;
  bool hb_pending_ = false;
  int32_t rtt_ms_ = -1;
  uint32_t dropped_ = 0;
  uint32_t acks_ = 0;
  bool device22_ = false;

  bool query_open_ = false;
  bool query_acked_ = false;
  uint32_t query_sent_ms_ = 0;
};

}  // namespace jarvis::tuya

#endif  // JARVIS_ESP32_TUYA_SESSION_H
