// Tuya LAN protocol codec — framing, crypto and payloads for protocol 3.3, 3.4 and 3.5.
//
// Pure C++ on top of mbedTLS (no Arduino headers), so the same file builds on the board
// and in the host test (tests/tuya_codec_test.cpp, vectors from tinytuya). tinytuya is
// the ground truth for every byte here:
//
//   3.3  000055AA | seq | cmd | len | body | CRC32 | 0000AA55
//        body = AES-128-ECB(local key, JSON), "3.3"+12×00 in front for most commands
//   3.4  same framing, HMAC-SHA256 (32 bytes) instead of the CRC, keyed by the session
//        key; the whole body (version header included) is AES-ECB under the session key.
//        Session key = AES-ECB(local key, client nonce XOR device nonce), agreed with
//        commands 3/4/5.
//   3.5  00006699 | 0000 | seq | cmd | len | IV(12) | AES-GCM ciphertext | tag(16) | 00009966
//        header after the prefix is the GCM AAD; session key = the GCM ciphertext of the
//        XORed nonces under the local key with IV = client nonce[0..11].
//
// Frames from the device carry a 4-byte return code in front of the body (inside the
// GCM plaintext for 3.5); frames we send carry none.
#ifndef JARVIS_ESP32_TUYA_CODEC_H
#define JARVIS_ESP32_TUYA_CODEC_H

#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include <string>
#include <vector>

#include <mbedtls/aes.h>
#include <mbedtls/gcm.h>
#include <mbedtls/md.h>

namespace jarvis::tuya {

using Bytes = std::vector<uint8_t>;

enum class Version : uint8_t { unknown = 0, v33 = 33, v34 = 34, v35 = 35 };

inline const char* version_name(Version v) {
  switch (v) {
    case Version::v33: return "3.3";
    case Version::v34: return "3.4";
    case Version::v35: return "3.5";
    default: return "auto";
  }
}

/// "3.3" / "3.4" / "3.5" → that version; anything else (including "auto") → unknown.
inline Version parse_version(const char* s) {
  if (s == nullptr) return Version::unknown;
  if (!strcmp(s, "3.3")) return Version::v33;
  if (!strcmp(s, "3.4")) return Version::v34;
  if (!strcmp(s, "3.5")) return Version::v35;
  return Version::unknown;
}

namespace cmd {
constexpr uint32_t sess_key_neg_start = 3;
constexpr uint32_t sess_key_neg_resp = 4;
constexpr uint32_t sess_key_neg_finish = 5;
constexpr uint32_t control = 7;
constexpr uint32_t status = 8;
constexpr uint32_t heart_beat = 9;
constexpr uint32_t dp_query = 0x0a;
constexpr uint32_t control_new = 0x0d;
constexpr uint32_t dp_query_new = 0x10;
constexpr uint32_t updatedps = 0x12;
constexpr uint32_t udp_new = 0x13;
constexpr uint32_t broadcast_lpv34 = 0x23;
constexpr uint32_t req_devinfo = 0x25;
constexpr uint32_t lan_ext_stream = 0x40;
}  // namespace cmd

constexpr uint32_t prefix_55aa = 0x000055AAu;
constexpr uint32_t suffix_55aa = 0x0000AA55u;
constexpr uint32_t prefix_6699 = 0x00006699u;
constexpr uint32_t suffix_6699 = 0x00009966u;
constexpr size_t header_55aa = 16;   // prefix, seq, cmd, len
constexpr size_t header_6699 = 18;   // prefix, 2 reserved bytes, seq, cmd, len
constexpr size_t version_header_len = 15;  // "3.x" + 12 zero bytes
/// tinytuya's sanity ceiling on a frame's length field; anything bigger is a desynced stream.
constexpr size_t max_payload = 1440;

/// md5("yGAdlopoPVldABfn") — the fixed key of the UDP discovery broadcasts.
inline constexpr uint8_t udp_key[16] = {0x6C, 0x1E, 0xC8, 0xE2, 0xBB, 0x9B, 0xB5, 0x9A,
                                        0xB5, 0x0B, 0x0D, 0xAF, 0x64, 0x9B, 0x41, 0x0A};

// ───────────────────────────── Bytes ─────────────────────────────

inline void put_u32(uint8_t* p, uint32_t v) {
  p[0] = static_cast<uint8_t>(v >> 24); p[1] = static_cast<uint8_t>(v >> 16);
  p[2] = static_cast<uint8_t>(v >> 8);  p[3] = static_cast<uint8_t>(v);
}
inline uint32_t get_u32(const uint8_t* p) {
  return (static_cast<uint32_t>(p[0]) << 24) | (static_cast<uint32_t>(p[1]) << 16) |
         (static_cast<uint32_t>(p[2]) << 8) | p[3];
}

/// Overwrites key material in a way the optimiser can't drop.
inline void secure_zero(void* p, size_t n) {
  volatile uint8_t* v = static_cast<volatile uint8_t*>(p);
  while (n--) *v++ = 0;
}

/// Constant-time compare for MACs.
inline bool equal_ct(const uint8_t* a, const uint8_t* b, size_t n) {
  uint8_t diff = 0;
  for (size_t i = 0; i < n; ++i) diff |= a[i] ^ b[i];
  return diff == 0;
}

// ───────────────────────────── Crypto ─────────────────────────────

/// zlib's CRC-32 (what Python's binascii.crc32 computes).
inline uint32_t crc32(const uint8_t* p, size_t n) {
  uint32_t c = 0xFFFFFFFFu;
  for (size_t i = 0; i < n; ++i) {
    c ^= p[i];
    for (int k = 0; k < 8; ++k) c = (c >> 1) ^ (0xEDB88320u & (0u - (c & 1u)));
  }
  return ~c;
}

inline void hmac_sha256(const uint8_t* key, size_t key_len, const uint8_t* data, size_t len, uint8_t out[32]) {
  static const uint8_t empty = 0;
  mbedtls_md_hmac(mbedtls_md_info_from_type(MBEDTLS_MD_SHA256), key, key_len, data ? data : &empty, len, out);
}

/// AES-128-ECB over whole blocks. `in` and `out` may be the same buffer.
inline bool aes_ecb(bool encrypt, const uint8_t key[16], const uint8_t* in, size_t len, uint8_t* out) {
  if (len % 16 != 0) return false;
  mbedtls_aes_context ctx;
  mbedtls_aes_init(&ctx);
  int rc = encrypt ? mbedtls_aes_setkey_enc(&ctx, key, 128) : mbedtls_aes_setkey_dec(&ctx, key, 128);
  for (size_t off = 0; rc == 0 && off < len; off += 16) {
    rc = mbedtls_aes_crypt_ecb(&ctx, encrypt ? MBEDTLS_AES_ENCRYPT : MBEDTLS_AES_DECRYPT, in + off, out + off);
  }
  mbedtls_aes_free(&ctx);
  return rc == 0;
}

/// PKCS#7-pads and encrypts (always adds at least one byte of padding).
inline Bytes ecb_encrypt_padded(const uint8_t key[16], const uint8_t* data, size_t len) {
  const size_t pad = 16 - (len % 16);
  Bytes out(len + pad);
  if (len) memcpy(out.data(), data, len);
  memset(out.data() + len, static_cast<int>(pad), pad);
  if (!aes_ecb(true, key, out.data(), out.size(), out.data())) out.clear();
  return out;
}

/// Decrypts and strips PKCS#7 padding; false when the length or the padding is wrong
/// (which is what a wrong key looks like).
inline bool ecb_decrypt_unpad(const uint8_t key[16], const uint8_t* data, size_t len, Bytes& out) {
  out.clear();
  if (len == 0 || len % 16 != 0) return false;
  out.resize(len);
  if (!aes_ecb(false, key, data, len, out.data())) { out.clear(); return false; }
  const uint8_t pad = out.back();
  if (pad < 1 || pad > 16) { out.clear(); return false; }
  for (size_t i = len - pad; i < len; ++i) {
    if (out[i] != pad) { out.clear(); return false; }
  }
  out.resize(len - pad);
  return true;
}

/// AES-128-GCM with a 12-byte IV and a 16-byte tag. Decryption returns false on a tag
/// mismatch.
inline bool gcm_crypt(bool encrypt, const uint8_t key[16], const uint8_t iv[12], const uint8_t* aad, size_t aad_len,
                      const uint8_t* in, size_t len, uint8_t* out, uint8_t tag[16]) {
  static uint8_t dummy[1];
  mbedtls_gcm_context ctx;
  mbedtls_gcm_init(&ctx);
  int rc = mbedtls_gcm_setkey(&ctx, MBEDTLS_CIPHER_ID_AES, key, 128);
  if (rc == 0) {
    rc = encrypt ? mbedtls_gcm_crypt_and_tag(&ctx, MBEDTLS_GCM_ENCRYPT, len, iv, 12, aad, aad_len,
                                             len ? in : dummy, len ? out : dummy, 16, tag)
                 : mbedtls_gcm_auth_decrypt(&ctx, len, iv, 12, aad, aad_len, tag, 16,
                                            len ? in : dummy, len ? out : dummy);
  }
  mbedtls_gcm_free(&ctx);
  return rc == 0;
}

// ───────────────────────────── Framing ─────────────────────────────

/// A client→device 55AA frame. `hmac_key` (16 bytes) selects the 3.4 HMAC trailer;
/// null selects the CRC32 trailer.
inline Bytes pack_55aa(uint32_t seq, uint32_t command, const uint8_t* body, size_t len, const uint8_t* hmac_key) {
  const size_t end = hmac_key ? 36 : 8;
  Bytes out(header_55aa + len + end);
  put_u32(&out[0], prefix_55aa);
  put_u32(&out[4], seq);
  put_u32(&out[8], command);
  put_u32(&out[12], static_cast<uint32_t>(len + end));
  if (len) memcpy(&out[header_55aa], body, len);
  if (hmac_key) {
    hmac_sha256(hmac_key, 16, out.data(), header_55aa + len, &out[header_55aa + len]);
  } else {
    put_u32(&out[header_55aa + len], crc32(out.data(), header_55aa + len));
  }
  put_u32(&out[out.size() - 4], suffix_55aa);
  return out;
}

/// A client→device 6699 frame (no return code), GCM under `key`.
inline Bytes pack_6699(uint32_t seq, uint32_t command, const uint8_t* body, size_t len, const uint8_t key[16],
                       const uint8_t iv[12]) {
  const size_t msg_len = 12 + len + 16;
  Bytes out(header_6699 + msg_len + 4);
  put_u32(&out[0], prefix_6699);
  out[4] = 0; out[5] = 0;
  put_u32(&out[6], seq);
  put_u32(&out[10], command);
  put_u32(&out[14], static_cast<uint32_t>(msg_len));
  memcpy(&out[header_6699], iv, 12);
  uint8_t* ct = &out[header_6699 + 12];
  uint8_t* tag = ct + len;
  if (!gcm_crypt(true, key, iv, &out[4], header_6699 - 4, body, len, ct, tag)) return Bytes();
  put_u32(&out[out.size() - 4], suffix_6699);
  return out;
}

enum class Unpack : uint8_t {
  ok,
  need_more,   // not a whole frame yet
  bad_prefix,  // doesn't start with 55AA / 6699
  too_large,   // length field over max_payload: the stream is desynced
  bad_length,  // length field too small for the trailer
  bad_check,   // CRC / HMAC / GCM tag mismatch (or no key for a 6699 frame)
};

/// How to treat the 4-byte return code inside a 6699 plaintext.
enum class Retcode : uint8_t { always, guess };

struct Frame {
  uint32_t prefix = 0;
  uint32_t seq = 0;
  uint32_t cmd = 0;
  uint32_t retcode = 0;
  Bytes payload;
};

/// Reads just the header: which framing, and the whole frame's size.
inline Unpack frame_size(const uint8_t* buf, size_t len, uint32_t& prefix, size_t& total) {
  if (len < 4) return Unpack::need_more;
  prefix = get_u32(buf);
  if (prefix == prefix_55aa) {
    if (len < header_55aa) return Unpack::need_more;
    const uint32_t plen = get_u32(buf + 12);
    if (plen > max_payload) return Unpack::too_large;
    total = header_55aa + plen;
    return Unpack::ok;
  }
  if (prefix == prefix_6699) {
    if (len < header_6699) return Unpack::need_more;
    const uint32_t plen = get_u32(buf + 14);
    if (plen > max_payload) return Unpack::too_large;
    total = header_6699 + plen + 4;
    return Unpack::ok;
  }
  return Unpack::bad_prefix;
}

/// Offset of the first frame prefix in `buf`. When there is none, everything but the
/// last three bytes (a possible partial prefix) can be dropped, so that is returned.
inline size_t find_prefix(const uint8_t* buf, size_t len) {
  if (len < 4) return 0;
  for (size_t i = 0; i + 4 <= len; ++i) {
    if (buf[i] == 0 && buf[i + 1] == 0 &&
        ((buf[i + 2] == 0x55 && buf[i + 3] == 0xAA) || (buf[i + 2] == 0x66 && buf[i + 3] == 0x99))) {
      return i;
    }
  }
  return len - 3;
}

/// True when a whole 55AA frame's trailer is a valid CRC32 — used to tell a 3.3 reply
/// apart from a 3.4 one whose HMAC didn't verify.
inline bool crc32_trailer_valid(const uint8_t* buf, size_t total) {
  if (total < header_55aa + 8) return false;
  return crc32(buf, total - 8) == get_u32(buf + total - 8);
}

/// Parses and verifies one device→client frame at the start of `buf`. For 55AA frames
/// `key` + `hmac` select the HMAC trailer (3.4); otherwise the CRC is checked. 6699
/// frames need `key` for GCM. `consumed` is the whole frame's size whenever the header
/// was readable (so the caller can skip a bad frame).
inline Unpack unpack(const uint8_t* buf, size_t len, const uint8_t* key, bool hmac, Frame& out, size_t& consumed,
                     Retcode retcode_mode = Retcode::always) {
  consumed = 0;
  out = Frame();
  uint32_t prefix = 0;
  size_t total = 0;
  const Unpack h = frame_size(buf, len, prefix, total);
  if (h != Unpack::ok) return h;
  if (len < total) return Unpack::need_more;
  consumed = total;
  out.prefix = prefix;

  if (prefix == prefix_55aa) {
    out.seq = get_u32(buf + 4);
    out.cmd = get_u32(buf + 8);
    const bool use_hmac = hmac && key != nullptr;
    const size_t end = use_hmac ? 36 : 8;
    const size_t plen = total - header_55aa;
    if (plen < 4 + end) return Unpack::bad_length;
    if (use_hmac) {
      uint8_t mac[32];
      hmac_sha256(key, 16, buf, total - end, mac);
      if (!equal_ct(mac, buf + total - end, 32)) return Unpack::bad_check;
    } else if (!crc32_trailer_valid(buf, total)) {
      return Unpack::bad_check;
    }
    out.retcode = get_u32(buf + header_55aa);
    out.payload.assign(buf + header_55aa + 4, buf + total - end);
    return Unpack::ok;
  }

  // 6699
  out.seq = get_u32(buf + 6);
  out.cmd = get_u32(buf + 10);
  const size_t plen = total - header_6699 - 4;
  if (plen < 12 + 16) return Unpack::bad_length;
  if (key == nullptr) return Unpack::bad_check;
  const uint8_t* iv = buf + header_6699;
  const uint8_t* ct = iv + 12;
  const size_t ct_len = plen - 12 - 16;
  uint8_t tag[16];
  memcpy(tag, ct + ct_len, 16);
  Bytes plain(ct_len);
  if (!gcm_crypt(false, key, iv, buf + 4, header_6699 - 4, ct, ct_len, plain.data(), tag)) return Unpack::bad_check;
  bool strip = plain.size() >= 4;
  if (retcode_mode == Retcode::guess) {
    strip = plain.size() > 4 && plain[0] != '{' && plain[4] == '{';
  }
  if (strip) {
    out.retcode = get_u32(plain.data());
    out.payload.assign(plain.begin() + 4, plain.end());
  } else {
    out.payload.swap(plain);
  }
  return Unpack::ok;
}

// ───────────────────────────── Messages ─────────────────────────────

/// Commands that never carry the "3.x"+12×00 version header (tinytuya NO_PROTOCOL_HEADER_CMDS).
inline bool skips_version_header(uint32_t command) {
  switch (command) {
    case cmd::dp_query: case cmd::dp_query_new: case cmd::updatedps: case cmd::heart_beat:
    case cmd::sess_key_neg_start: case cmd::sess_key_neg_resp: case cmd::sess_key_neg_finish:
    case cmd::lan_ext_stream:
      return true;
    default:
      return false;
  }
}

inline void append_version_header(Bytes& out, Version v) {
  const char* name = version_name(v);
  out.insert(out.end(), name, name + 3);
  out.insert(out.end(), 12, 0);
}

/// One client→device message, byte-exact with tinytuya's _encode_message. `key` is the
/// local key (3.3, and 3.4/3.5 during negotiation) or the session key; `iv` is needed
/// for 3.5 only.
inline Bytes encode_message(Version v, const uint8_t key[16], uint32_t seq, uint32_t command, const uint8_t* payload,
                            size_t len, const uint8_t* iv) {
  if (v == Version::v34 || v == Version::v35) {
    Bytes body;
    body.reserve(version_header_len + len);
    if (!skips_version_header(command)) append_version_header(body, v);
    body.insert(body.end(), payload, payload + len);
    if (v == Version::v35) {
      if (iv == nullptr) return Bytes();
      return pack_6699(seq, command, body.data(), body.size(), key, iv);
    }
    const Bytes enc = ecb_encrypt_padded(key, body.data(), body.size());
    return pack_55aa(seq, command, enc.data(), enc.size(), key);
  }
  if (v != Version::v33) return Bytes();
  const Bytes enc = ecb_encrypt_padded(key, payload, len);
  Bytes body;
  body.reserve(version_header_len + enc.size());
  if (!skips_version_header(command)) append_version_header(body, v);
  body.insert(body.end(), enc.begin(), enc.end());
  return pack_55aa(seq, command, body.data(), body.size(), nullptr);
}

inline Bytes encode_message(Version v, const uint8_t key[16], uint32_t seq, uint32_t command,
                            const std::string& payload, const uint8_t* iv) {
  return encode_message(v, key, seq, command, reinterpret_cast<const uint8_t*>(payload.data()), payload.size(), iv);
}

// JSON bodies, exactly as tinytuya builds them (json.dumps with every space removed).
// `dev_id` is spliced in raw: the caller only accepts [A-Za-z0-9_-] ids.

/// DP_QUERY for 3.3 (DP_QUERY_NEW with an empty object for 3.4/3.5). "device22" 3.3
/// devices answer the normal form with "data unvalid" and want CONTROL_NEW + a dps list.
inline std::string query_json(Version v, const std::string& dev_id, uint32_t t, bool device22) {
  if (v == Version::v34 || v == Version::v35) return "{}";
  const std::string ts = std::to_string(t);
  if (device22) {
    return "{\"devId\":\"" + dev_id + "\",\"uid\":\"" + dev_id + "\",\"t\":\"" + ts + "\",\"dps\":{\"1\":null}}";
  }
  return "{\"gwId\":\"" + dev_id + "\",\"devId\":\"" + dev_id + "\",\"uid\":\"" + dev_id + "\",\"t\":\"" + ts + "\"}";
}

inline uint32_t query_cmd(Version v, bool device22) {
  if (v == Version::v34 || v == Version::v35) return cmd::dp_query_new;
  return device22 ? cmd::control_new : cmd::dp_query;
}

/// CONTROL (3.3) / CONTROL_NEW (3.4, 3.5). `dps_json` is a JSON object, e.g. {"1":true}.
inline std::string control_json(Version v, const std::string& dev_id, const std::string& dps_json, uint32_t t) {
  if (v == Version::v34 || v == Version::v35) {
    return "{\"protocol\":5,\"t\":" + std::to_string(t) + ",\"data\":{\"dps\":" + dps_json + "}}";
  }
  return "{\"devId\":\"" + dev_id + "\",\"uid\":\"" + dev_id + "\",\"t\":\"" + std::to_string(t) + "\",\"dps\":" +
         dps_json + "}";
}

inline uint32_t control_cmd(Version v) {
  return (v == Version::v34 || v == Version::v35) ? cmd::control_new : cmd::control;
}

inline std::string heartbeat_json(const std::string& dev_id) {
  return "{\"gwId\":\"" + dev_id + "\",\"devId\":\"" + dev_id + "\"}";
}

enum class Decoded : uint8_t { json, empty, bad, unvalid };

inline bool looks_like_json(const Bytes& p) {
  return p.size() >= 2 && p.front() == '{' && p.back() == '}';
}

inline bool starts_with(const Bytes& p, const char* s, size_t n) {
  return p.size() >= n && memcmp(p.data(), s, n) == 0;
}

/// A device frame's payload (return code already stripped) → its JSON text: version
/// header removed, decrypted for 3.3/3.4 (3.5 arrives decrypted by unpack()). `bad`
/// means it didn't decrypt to JSON; `unvalid` is a 3.3 "device22" refusal.
inline Decoded decode_payload(Version v, const uint8_t key[16], const Bytes& payload, std::string& json) {
  json.clear();
  if (payload.empty()) return Decoded::empty;
  Bytes p;
  const char* vname = version_name(v);
  if (v == Version::v34) {
    if (!ecb_decrypt_unpad(key, payload.data(), payload.size(), p)) return Decoded::bad;
    if (starts_with(p, vname, 3)) {
      if (p.size() < version_header_len) return Decoded::bad;
      p.erase(p.begin(), p.begin() + version_header_len);
    }
  } else if (v == Version::v35) {
    p = payload;
    if (starts_with(p, vname, 3)) {
      if (p.size() < version_header_len) return Decoded::bad;
      p.erase(p.begin(), p.begin() + version_header_len);
    }
  } else if (v == Version::v33) {
    Bytes body = payload;
    if (starts_with(body, vname, 3)) {
      if (body.size() < version_header_len) return Decoded::bad;
      body.erase(body.begin(), body.begin() + version_header_len);
    }
    if (body.empty()) return Decoded::empty;
    if (!ecb_decrypt_unpad(key, body.data(), body.size(), p)) {
      // A few firmwares answer in the clear.
      if (!looks_like_json(body) || body.size() % 16 == 0) return Decoded::bad;
      p.swap(body);
    }
  } else {
    return Decoded::bad;
  }
  static const char unvalid[] = "data unvalid";
  if (p.size() >= sizeof(unvalid) - 1) {
    for (size_t i = 0; i + sizeof(unvalid) - 1 <= p.size(); ++i) {
      if (memcmp(p.data() + i, unvalid, sizeof(unvalid) - 1) == 0) return Decoded::unvalid;
    }
  }
  if (p.empty()) return Decoded::empty;
  if (p.front() != '{') return Decoded::bad;
  json.assign(p.begin(), p.end());
  return Decoded::json;
}

// ───────────────────────────── Session key (3.4 / 3.5) ─────────────────────────────

inline void derive_session_key(Version v, const uint8_t local_key[16], const uint8_t client_nonce[16],
                               const uint8_t remote_nonce[16], uint8_t out[16]) {
  uint8_t x[16];
  for (int i = 0; i < 16; ++i) x[i] = client_nonce[i] ^ remote_nonce[i];
  if (v == Version::v35) {
    uint8_t tag[16];
    gcm_crypt(true, local_key, client_nonce, nullptr, 0, x, 16, out, tag);
  } else {
    aes_ecb(true, local_key, x, 16, out);
  }
  secure_zero(x, sizeof(x));
}

// ───────────────────────────── Discovery ─────────────────────────────

inline void rstrip_nul(Bytes& p) {
  while (!p.empty() && p.back() == 0) p.pop_back();
}

/// A UDP discovery broadcast (ports 6666 / 6667 / 7000) → its JSON, like tinytuya's
/// decrypt_udp: plaintext or AES-ECB(udp_key) inside a 55AA frame, AES-GCM(udp_key)
/// inside a 6699 frame, or a bare AES-ECB blob.
inline bool decode_broadcast(const uint8_t* data, size_t len, std::string& json) {
  json.clear();
  if (data == nullptr || len < 4) return false;
  Bytes p;
  uint32_t prefix = 0;
  size_t total = 0;
  if (frame_size(data, len, prefix, total) == Unpack::ok && total <= len) {
    Frame f;
    size_t used = 0;
    if (unpack(data, total, udp_key, false, f, used, Retcode::guess) != Unpack::ok) return false;
    if (prefix == prefix_55aa) {
      if (looks_like_json(f.payload)) p.swap(f.payload);
      else if (!ecb_decrypt_unpad(udp_key, f.payload.data(), f.payload.size(), p)) return false;
    } else {
      p.swap(f.payload);
      rstrip_nul(p);
    }
  } else if (!ecb_decrypt_unpad(udp_key, data, len, p)) {
    return false;
  }
  if (!looks_like_json(p)) return false;
  json.assign(p.begin(), p.end());
  return true;
}

/// The "who's there" broadcast to UDP 7000 that makes 3.5 devices announce themselves.
inline Bytes devinfo_request(const std::string& my_ip, const uint8_t iv[12]) {
  // json.dumps default separators — this one keeps its spaces.
  const std::string body = "{\"from\": \"app\", \"ip\": \"" + my_ip + "\"}";
  return pack_6699(0, cmd::req_devinfo, reinterpret_cast<const uint8_t*>(body.data()), body.size(), udp_key, iv);
}

}  // namespace jarvis::tuya

#endif  // JARVIS_ESP32_TUYA_CODEC_H
