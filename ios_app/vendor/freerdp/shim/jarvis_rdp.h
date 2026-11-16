// Jarvis Remote Desktop: the small C API Swift uses (RdpClient.swift), over FreeRDP 3.
// One session = one FreeRDP client context on its own thread. Input calls are queued and run on
// that thread; callbacks arrive on it too (copy what you need, hop to the main thread yourself).
#ifndef JARVIS_RDP_H
#define JARVIS_RDP_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct jrdp_session jrdp_session;

enum {
    JRDP_STATE_CONNECTING = 1,
    JRDP_STATE_CONNECTED = 2,
    JRDP_STATE_ENDED = 3,
};

typedef struct {
    void *user;
    /// The whole framebuffer (BGRA, premultiplied, top-down) and the rectangle that changed.
    void (*on_frame)(void *user, const uint8_t *bgra, int width, int height, int stride,
                     int x, int y, int w, int h);
    /// The desktop size changed (server resize or our display-control request).
    void (*on_resize)(void *user, int width, int height);
    /// Connection state; for ENDED, `error` is FreeRDP's last error (0 = a clean disconnect).
    void (*on_state)(void *user, int state, uint32_t error, const char *message);
    /// Text the PC copied (UTF-8).
    void (*on_clipboard_text)(void *user, const char *utf8);
} jrdp_callbacks;

typedef struct {
    const char *host;
    int port;
    const char *username;
    const char *password;
    const char *domain;      // may be NULL
    int width;
    int height;
    int audio;               // 1 = play the PC's sound here (rdpsnd)
    const char *drive_path;  // may be NULL: a local folder shown on the PC as a drive
    const char *drive_name;
} jrdp_config;

jrdp_session *jrdp_create(const jrdp_callbacks *callbacks);
/// Starts connecting on the session's thread. 0 = started.
int jrdp_connect(jrdp_session *s, const jrdp_config *config);
/// Asks the session to end; returns at once. ENDED arrives on the callback.
void jrdp_disconnect(jrdp_session *s);
/// Waits for the thread and frees everything (call after ENDED, or it disconnects first).
void jrdp_free(jrdp_session *s);

void jrdp_mouse_move(jrdp_session *s, int x, int y);
/// button: 1 left, 2 right, 3 middle.
void jrdp_mouse_button(jrdp_session *s, int button, int down, int x, int y);
/// Positive scrolls up / right.
void jrdp_wheel(jrdp_session *s, int delta, int horizontal, int x, int y);
/// A PC scancode (set 1), `extended` for the E0 keys (arrows, Win, right Ctrl/Alt, …).
void jrdp_key(jrdp_session *s, int scancode, int extended, int down);
void jrdp_unicode(jrdp_session *s, int codepoint, int down);
/// Asks the PC to resize the desktop (display-control channel); even width ≥ 200.
void jrdp_resize(jrdp_session *s, int width, int height);
/// Offers text from this device's clipboard to the PC.
void jrdp_clipboard_set_text(jrdp_session *s, const char *utf8);

/// FreeRDP error codes Swift maps to words (see RdpClient.swift).
uint32_t jrdp_error_auth_failed(void);
uint32_t jrdp_error_logon_failure(void);
uint32_t jrdp_error_wrong_password(void);
uint32_t jrdp_error_account_disabled(void);
uint32_t jrdp_error_password_expired(void);
uint32_t jrdp_error_connect_failed(void);
uint32_t jrdp_error_dns_name_not_found(void);

#ifdef __cplusplus
}
#endif

#endif
