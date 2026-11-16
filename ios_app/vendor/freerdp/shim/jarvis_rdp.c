// Jarvis Remote Desktop shim over FreeRDP 3 (see jarvis_rdp.h). Modelled on FreeRDP's own iOS
// glue (client/iOS/FreeRDP/ios_freerdp.m, ios_cliprdr.m; Apache-2.0): software GDI to a BGRA
// framebuffer, GFX through gdi_graphics_pipeline_init, text clipboard (cliprdr), display control
// (disp) for resizes, rdpsnd's iOS backend for sound and rdpdr's drive for files.
// The build's own config first: it defines WITHOUT_FREERDP_3x_DEPRECATED and friends, which
// change the layout of rdpContext / rdpUpdate. Without it the shim and the library disagree on
// struct offsets (post_connect wrote BeginPaint through a NULL `update`).
#include <winpr/config.h>
#include <freerdp/config.h>

#include "jarvis_rdp.h"

#include <pthread.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>

#include <winpr/clipboard.h>
#include <winpr/synch.h>
#include <winpr/user.h>
#include <freerdp/freerdp.h>
#include <freerdp/client.h>
#include <freerdp/error.h>
#include <freerdp/event.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/gdi/gfx.h>
#include <freerdp/channels/channels.h>
#include <freerdp/client/channels.h>
#include <freerdp/client/cmdline.h>
#include <freerdp/client/cliprdr.h>
#include <freerdp/client/disp.h>
#include <freerdp/channels/disp.h>

// MARK: - Input queue (filled from any thread, drained on the session thread)

typedef enum { EV_MOUSE, EV_KEY, EV_UNICODE, EV_RESIZE, EV_CLIP } ev_kind;

typedef struct ev {
    ev_kind kind;
    uint16_t flags;
    uint16_t x, y;
    uint32_t code;
    int down;
    int w, h;
    char *text;
    struct ev *next;
} ev;

struct jrdp_session {
    jrdp_callbacks cb;
    freerdp *instance;
    pthread_t thread;
    int has_thread;
    volatile int stop;
    HANDLE wake;
    pthread_mutex_t lock;
    ev *head, *tail;
    char *local_text;     // this device's clipboard, offered to the PC
    int clip_ready;
    // Channel state lives here, not in the context: the shim never relies on FreeRDP's
    // rdpClientContext layout (it grows between releases and with build options).
    CliprdrClientContext *cliprdr;
    DispClientContext *disp;
    wClipboard *clipboard;
    UINT32 requested_format;
    CLIPRDR_FORMAT *server_formats;
    UINT32 server_format_count;
};

typedef jrdp_session jctx;   // the channel helpers below take the session

// freerdp* → session, for callbacks that only get the instance / context.
#define JRDP_MAX_SESSIONS 8
static pthread_mutex_t table_lock = PTHREAD_MUTEX_INITIALIZER;
static struct { freerdp *instance; jrdp_session *s; } table[JRDP_MAX_SESSIONS];

static void table_put(freerdp *instance, jrdp_session *s) {
    pthread_mutex_lock(&table_lock);
    for (int i = 0; i < JRDP_MAX_SESSIONS; i++)
        if (!table[i].instance) { table[i].instance = instance; table[i].s = s; break; }
    pthread_mutex_unlock(&table_lock);
}

static void table_drop(freerdp *instance) {
    pthread_mutex_lock(&table_lock);
    for (int i = 0; i < JRDP_MAX_SESSIONS; i++)
        if (table[i].instance == instance) { table[i].instance = NULL; table[i].s = NULL; }
    pthread_mutex_unlock(&table_lock);
}

static jrdp_session *session_of(rdpContext *context) {
    jrdp_session *s = NULL;
    if (!context) return NULL;
    pthread_mutex_lock(&table_lock);
    for (int i = 0; i < JRDP_MAX_SESSIONS; i++)
        if (table[i].instance == context->instance) { s = table[i].s; break; }
    pthread_mutex_unlock(&table_lock);
    return s;
}

static void push(jrdp_session *s, ev *e) {
    pthread_mutex_lock(&s->lock);
    if (s->tail) s->tail->next = e; else s->head = e;
    s->tail = e;
    pthread_mutex_unlock(&s->lock);
    (void)SetEvent(s->wake);
}

static ev *new_ev(ev_kind kind) {
    ev *e = calloc(1, sizeof(ev));
    if (e) e->kind = kind;
    return e;
}

// MARK: - Clipboard (text only)

static void free_formats(jctx *c) {
    for (UINT32 i = 0; i < c->server_format_count; i++) free(c->server_formats[i].formatName);
    free(c->server_formats);
    c->server_formats = NULL;
    c->server_format_count = 0;
}

static UINT send_format_list(jctx *c) {
    if (!c->cliprdr || !c->cliprdr->ClientFormatList) return ERROR_INVALID_PARAMETER;
    CLIPRDR_FORMAT format = { 0 };
    CLIPRDR_FORMAT_LIST list = { 0 };
    format.formatId = CF_UNICODETEXT;
    list.common.msgType = CB_FORMAT_LIST;
    pthread_mutex_lock(&c->lock);
    list.numFormats = c->local_text ? 1 : 0;
    pthread_mutex_unlock(&c->lock);
    list.formats = &format;
    return c->cliprdr->ClientFormatList(c->cliprdr, &list);
}

static UINT clip_monitor_ready(CliprdrClientContext *cliprdr, const CLIPRDR_MONITOR_READY *ready) {
    (void)ready;
    jctx *c = (jctx *)cliprdr->custom;
    CLIPRDR_CAPABILITIES caps = { 0 };
    CLIPRDR_GENERAL_CAPABILITY_SET general = { 0 };
    caps.cCapabilitiesSets = 1;
    caps.capabilitySets = (CLIPRDR_CAPABILITY_SET *)&general;
    general.capabilitySetType = CB_CAPSTYPE_GENERAL;
    general.capabilitySetLength = 12;
    general.version = CB_CAPS_VERSION_2;
    general.generalFlags = CB_USE_LONG_FORMAT_NAMES;
    UINT rc = cliprdr->ClientCapabilities(cliprdr, &caps);
    if (rc != CHANNEL_RC_OK) return rc;
    c->clip_ready = 1;
    return send_format_list(c);
}

static UINT clip_server_caps(CliprdrClientContext *cliprdr, const CLIPRDR_CAPABILITIES *caps) {
    (void)cliprdr; (void)caps;
    return CHANNEL_RC_OK;
}

static UINT clip_server_format_list(CliprdrClientContext *cliprdr, const CLIPRDR_FORMAT_LIST *list) {
    jctx *c = (jctx *)cliprdr->custom;
    free_formats(c);
    CLIPRDR_FORMAT_LIST_RESPONSE ok = { 0 };
    ok.common.msgType = CB_FORMAT_LIST_RESPONSE;
    ok.common.msgFlags = CB_RESPONSE_OK;
    if (list->numFormats > 0) {
        c->server_formats = calloc(list->numFormats, sizeof(CLIPRDR_FORMAT));
        if (!c->server_formats) return CHANNEL_RC_NO_MEMORY;
        c->server_format_count = list->numFormats;
        for (UINT32 i = 0; i < list->numFormats; i++) {
            c->server_formats[i].formatId = list->formats[i].formatId;
            if (list->formats[i].formatName) c->server_formats[i].formatName = _strdup(list->formats[i].formatName);
        }
    }
    UINT rc = cliprdr->ClientFormatListResponse(cliprdr, &ok);
    if (rc != CHANNEL_RC_OK) return rc;
    UINT32 want = 0;
    for (UINT32 i = 0; i < c->server_format_count; i++) {
        if (c->server_formats[i].formatId == CF_UNICODETEXT) { want = CF_UNICODETEXT; break; }
        if (c->server_formats[i].formatId == CF_TEXT) want = CF_TEXT;
    }
    if (!want) return CHANNEL_RC_OK;
    CLIPRDR_FORMAT_DATA_REQUEST req = { 0 };
    req.common.msgType = CB_FORMAT_DATA_REQUEST;
    req.requestedFormatId = want;
    c->requested_format = want;
    return cliprdr->ClientFormatDataRequest(cliprdr, &req);
}

static UINT clip_server_format_list_response(CliprdrClientContext *cliprdr, const CLIPRDR_FORMAT_LIST_RESPONSE *r) {
    (void)cliprdr; (void)r;
    return CHANNEL_RC_OK;
}

static UINT clip_server_lock(CliprdrClientContext *cliprdr, const CLIPRDR_LOCK_CLIPBOARD_DATA *d) {
    (void)cliprdr; (void)d;
    return CHANNEL_RC_OK;
}

static UINT clip_server_unlock(CliprdrClientContext *cliprdr, const CLIPRDR_UNLOCK_CLIPBOARD_DATA *d) {
    (void)cliprdr; (void)d;
    return CHANNEL_RC_OK;
}

static UINT clip_server_data_request(CliprdrClientContext *cliprdr, const CLIPRDR_FORMAT_DATA_REQUEST *req) {
    jctx *c = (jctx *)cliprdr->custom;
    CLIPRDR_FORMAT_DATA_RESPONSE resp = { 0 };
    resp.common.msgType = CB_FORMAT_DATA_RESPONSE;
    BYTE *data = NULL;
    UINT32 size = 0;
    UINT32 id = req->requestedFormatId;
    pthread_mutex_lock(&c->lock);
    char *text = c->local_text ? _strdup(c->local_text) : NULL;
    pthread_mutex_unlock(&c->lock);
    if (text && (id == CF_UNICODETEXT || id == CF_TEXT || id == CF_OEMTEXT)) {
        ClipboardLock(c->clipboard);
        if (ClipboardSetData(c->clipboard, ClipboardRegisterFormat(c->clipboard, "UTF8_STRING"), text,
                             (UINT32)strlen(text) + 1))
            data = (BYTE *)ClipboardGetData(c->clipboard, id, &size);
        ClipboardUnlock(c->clipboard);
    }
    free(text);
    resp.common.msgFlags = data ? CB_RESPONSE_OK : CB_RESPONSE_FAIL;
    resp.common.dataLen = data ? size : 0;
    resp.requestedFormatData = data;
    UINT rc = cliprdr->ClientFormatDataResponse(cliprdr, &resp);
    free(data);
    return rc;
}

static UINT clip_server_data_response(CliprdrClientContext *cliprdr, const CLIPRDR_FORMAT_DATA_RESPONSE *resp) {
    jctx *c = (jctx *)cliprdr->custom;
    if ((resp->common.msgFlags & CB_RESPONSE_FAIL) || !resp->requestedFormatData || resp->common.dataLen == 0)
        return CHANNEL_RC_OK;
    UINT32 size = 0;
    char *utf8 = NULL;
    ClipboardLock(c->clipboard);
    if (ClipboardSetData(c->clipboard, c->requested_format, resp->requestedFormatData, resp->common.dataLen))
        utf8 = (char *)ClipboardGetData(c->clipboard, ClipboardRegisterFormat(c->clipboard, "UTF8_STRING"), &size);
    ClipboardUnlock(c->clipboard);
    if (utf8 && c->cb.on_clipboard_text) {
        char *z = calloc(1, (size_t)size + 1);
        if (z) {
            memcpy(z, utf8, size);
            c->cb.on_clipboard_text(c->cb.user, z);
            free(z);
        }
    }
    free(utf8);
    return CHANNEL_RC_OK;
}

static void clip_init(jctx *c, CliprdrClientContext *cliprdr) {
    c->cliprdr = cliprdr;
    c->clipboard = ClipboardCreate();
    cliprdr->custom = c;
    cliprdr->MonitorReady = clip_monitor_ready;
    cliprdr->ServerCapabilities = clip_server_caps;
    cliprdr->ServerFormatList = clip_server_format_list;
    cliprdr->ServerFormatListResponse = clip_server_format_list_response;
    cliprdr->ServerLockClipboardData = clip_server_lock;
    cliprdr->ServerUnlockClipboardData = clip_server_unlock;
    cliprdr->ServerFormatDataRequest = clip_server_data_request;
    cliprdr->ServerFormatDataResponse = clip_server_data_response;
}

static void clip_uninit(jctx *c) {
    if (c->cliprdr) c->cliprdr->custom = NULL;
    c->cliprdr = NULL;
    free_formats(c);
    if (c->clipboard) ClipboardDestroy(c->clipboard);
    c->clipboard = NULL;
}

// MARK: - Channels

static void on_channel_connected(void *context, const ChannelConnectedEventArgs *e) {
    rdpContext *ctx = (rdpContext *)context;
    jctx *c = session_of(ctx);
    if (!c) return;
    if (strcmp(e->name, RDPGFX_DVC_CHANNEL_NAME) == 0) {
        (void)gdi_graphics_pipeline_init(ctx->gdi, (RdpgfxClientContext *)e->pInterface);
    } else if (strcmp(e->name, CLIPRDR_SVC_CHANNEL_NAME) == 0) {
        clip_init(c, (CliprdrClientContext *)e->pInterface);
    } else if (strcmp(e->name, DISP_DVC_CHANNEL_NAME) == 0) {
        c->disp = (DispClientContext *)e->pInterface;
    }
}

static void on_channel_disconnected(void *context, const ChannelDisconnectedEventArgs *e) {
    rdpContext *ctx = (rdpContext *)context;
    jctx *c = session_of(ctx);
    if (!c) return;
    if (strcmp(e->name, RDPGFX_DVC_CHANNEL_NAME) == 0) {
        gdi_graphics_pipeline_uninit(ctx->gdi, (RdpgfxClientContext *)e->pInterface);
    } else if (strcmp(e->name, CLIPRDR_SVC_CHANNEL_NAME) == 0) {
        clip_uninit(c);
    } else if (strcmp(e->name, DISP_DVC_CHANNEL_NAME) == 0) {
        c->disp = NULL;
    }
}

// MARK: - Painting

static BOOL begin_paint(rdpContext *context) {
    rdpGdi *gdi = context->gdi;
    if (!gdi || !gdi->primary || !gdi->primary->hdc || !gdi->primary->hdc->hwnd) return TRUE;
    gdi->primary->hdc->hwnd->invalid->null = TRUE;
    gdi->primary->hdc->hwnd->ninvalid = 0;
    return TRUE;
}

static BOOL end_paint(rdpContext *context) {
    rdpGdi *gdi = context->gdi;
    jrdp_session *s = session_of(context);
    if (!s || !gdi || !gdi->primary || !gdi->primary->hdc || !gdi->primary->hdc->hwnd) return TRUE;
    HGDI_WND hwnd = gdi->primary->hdc->hwnd;
    if (hwnd->invalid->null) return TRUE;
    if (s->cb.on_frame)
        s->cb.on_frame(s->cb.user, gdi->primary_buffer, (int)gdi->width, (int)gdi->height, (int)gdi->stride,
                       hwnd->invalid->x, hwnd->invalid->y, hwnd->invalid->w, hwnd->invalid->h);
    return TRUE;
}

static BOOL desktop_resize(rdpContext *context) {
    rdpSettings *settings = context->settings;
    UINT32 w = freerdp_settings_get_uint32(settings, FreeRDP_DesktopWidth);
    UINT32 h = freerdp_settings_get_uint32(settings, FreeRDP_DesktopHeight);
    if (!gdi_resize(context->gdi, w, h)) return FALSE;
    jrdp_session *s = session_of(context);
    if (s && s->cb.on_resize) s->cb.on_resize(s->cb.user, (int)w, (int)h);
    return TRUE;
}

// MARK: - Connection callbacks

static BOOL pre_connect(freerdp *instance) {
    rdpContext *ctx = instance->context;
    if (PubSub_SubscribeChannelConnected(ctx->pubSub, on_channel_connected) != CHANNEL_RC_OK) return FALSE;
    if (PubSub_SubscribeChannelDisconnected(ctx->pubSub, on_channel_disconnected) != CHANNEL_RC_OK) return FALSE;
    return freerdp_client_load_addins(ctx->channels, ctx->settings);
}

static BOOL post_connect(freerdp *instance) {
    if (!gdi_init(instance, PIXEL_FORMAT_BGRA32)) return FALSE;
    rdpContext *ctx = instance->context;
    ctx->update->BeginPaint = begin_paint;
    ctx->update->EndPaint = end_paint;
    ctx->update->DesktopResize = desktop_resize;
    jrdp_session *s = session_of(ctx);
    if (s && s->cb.on_resize) s->cb.on_resize(s->cb.user, (int)ctx->gdi->width, (int)ctx->gdi->height);
    return TRUE;
}

static void post_disconnect(freerdp *instance) { gdi_free(instance); }

// The PC's certificate is self-signed; RDP's TLS runs end to end through Jarvis's relay, which
// only reaches the PC's Tailscale address. Accept for this connection only (2 = temporarily).
static DWORD verify_cert(freerdp *instance, const char *host, UINT16 port, const char *cn, const char *subject,
                         const char *issuer, const char *fingerprint, DWORD flags) {
    (void)instance; (void)host; (void)port; (void)cn; (void)subject; (void)issuer; (void)fingerprint; (void)flags;
    return 2;
}

static DWORD verify_changed_cert(freerdp *instance, const char *host, UINT16 port, const char *cn,
                                 const char *subject, const char *issuer, const char *fingerprint,
                                 const char *old_subject, const char *old_issuer, const char *old_fingerprint,
                                 DWORD flags) {
    (void)instance; (void)host; (void)port; (void)cn; (void)subject; (void)issuer; (void)fingerprint;
    (void)old_subject; (void)old_issuer; (void)old_fingerprint; (void)flags;
    return 2;
}

static BOOL client_new(freerdp *instance, rdpContext *context) {
    (void)context;
    instance->PreConnect = pre_connect;
    instance->PostConnect = post_connect;
    instance->PostDisconnect = post_disconnect;
    instance->VerifyCertificateEx = verify_cert;
    instance->VerifyChangedCertificateEx = verify_changed_cert;
    return TRUE;
}

static void client_free(freerdp *instance, rdpContext *context) { (void)instance; (void)context; }

// MARK: - Session thread

static void drain(jrdp_session *s) {
    rdpContext *ctx = s->instance->context;
    jctx *c = s;
    pthread_mutex_lock(&s->lock);
    ev *e = s->head;
    s->head = s->tail = NULL;
    (void)ResetEvent(s->wake);
    pthread_mutex_unlock(&s->lock);
    while (e) {
        ev *next = e->next;
        switch (e->kind) {
        case EV_MOUSE: (void)freerdp_input_send_mouse_event(ctx->input, e->flags, e->x, e->y); break;
        case EV_KEY: (void)freerdp_input_send_keyboard_event_ex(ctx->input, e->down, FALSE, e->code); break;
        case EV_UNICODE:
            (void)freerdp_input_send_unicode_keyboard_event(ctx->input, e->down ? 0 : KBD_FLAGS_RELEASE,
                                                            (UINT16)e->code);
            break;
        case EV_RESIZE:
            if (c->disp && c->disp->SendMonitorLayout) {
                DISPLAY_CONTROL_MONITOR_LAYOUT layout = { 0 };
                layout.Flags = DISPLAY_CONTROL_MONITOR_PRIMARY;
                layout.Width = (UINT32)e->w;
                layout.Height = (UINT32)e->h;
                layout.Orientation = ORIENTATION_LANDSCAPE;
                layout.DesktopScaleFactor = 100;
                layout.DeviceScaleFactor = 100;
                (void)c->disp->SendMonitorLayout(c->disp, 1, &layout);
            }
            break;
        case EV_CLIP:
            pthread_mutex_lock(&s->lock);
            free(s->local_text);
            s->local_text = e->text;
            e->text = NULL;
            pthread_mutex_unlock(&s->lock);
            if (c->cliprdr && s->clip_ready) (void)send_format_list(c);
            break;
        }
        free(e->text);
        free(e);
        e = next;
    }
}

static void *run(void *arg) {
    jrdp_session *s = arg;
    freerdp *instance = s->instance;
    rdpContext *ctx = instance->context;
    if (s->cb.on_state) s->cb.on_state(s->cb.user, JRDP_STATE_CONNECTING, 0, "");
    if (!freerdp_connect(instance)) {
        UINT32 err = freerdp_get_last_error(ctx);
        if (s->cb.on_state) s->cb.on_state(s->cb.user, JRDP_STATE_ENDED, err ? err : FREERDP_ERROR_CONNECT_FAILED,
                                           freerdp_get_last_error_string(err));
        return NULL;
    }
    if (s->cb.on_state) s->cb.on_state(s->cb.user, JRDP_STATE_CONNECTED, 0, "");
    while (!s->stop && !freerdp_shall_disconnect_context(ctx)) {
        HANDLE handles[MAXIMUM_WAIT_OBJECTS] = { 0 };
        DWORD n = freerdp_get_event_handles(ctx, handles, ARRAYSIZE(handles) - 1);
        if (n == 0) break;
        handles[n++] = s->wake;
        if (WaitForMultipleObjects(n, handles, FALSE, 1000) == WAIT_FAILED) break;
        if (!freerdp_check_event_handles(ctx)) break;
        drain(s);
    }
    UINT32 err = s->stop ? 0 : freerdp_get_last_error(ctx);
    freerdp_disconnect(instance);
    if (s->cb.on_state) s->cb.on_state(s->cb.user, JRDP_STATE_ENDED, err, err ? freerdp_get_last_error_string(err) : "");
    return NULL;
}

// MARK: - Public API

jrdp_session *jrdp_create(const jrdp_callbacks *callbacks) {
    signal(SIGPIPE, SIG_IGN);
    jrdp_session *s = calloc(1, sizeof(jrdp_session));
    if (!s) return NULL;
    s->cb = *callbacks;
    pthread_mutex_init(&s->lock, NULL);
    s->wake = CreateEvent(NULL, TRUE, FALSE, NULL);
    RDP_CLIENT_ENTRY_POINTS ep = { 0 };
    ep.Version = RDP_CLIENT_INTERFACE_VERSION;
    ep.Size = sizeof(RDP_CLIENT_ENTRY_POINTS_V1);
    // Bigger than any rdpClientContext FreeRDP 3 has had (it pads to ~129 slots after rdpContext);
    // nothing of ours is stored in it.
    ep.ContextSize = sizeof(rdpClientContext) + 8192;
    ep.ClientNew = client_new;
    ep.ClientFree = client_free;
    rdpContext *ctx = freerdp_client_context_new(&ep);
    if (!ctx) { jrdp_free(s); return NULL; }
    s->instance = ctx->instance;
    table_put(s->instance, s);
    return s;
}

int jrdp_connect(jrdp_session *s, const jrdp_config *cfg) {
    if (!s || !s->instance || s->has_thread) return -1;
    rdpSettings *st = s->instance->context->settings;
    BOOL ok = TRUE;
    ok &= freerdp_settings_set_string(st, FreeRDP_ServerHostname, cfg->host);
    ok &= freerdp_settings_set_uint32(st, FreeRDP_ServerPort, (UINT32)cfg->port);
    ok &= freerdp_settings_set_string(st, FreeRDP_Username, cfg->username);
    ok &= freerdp_settings_set_string(st, FreeRDP_Password, cfg->password);
    if (cfg->domain && *cfg->domain) ok &= freerdp_settings_set_string(st, FreeRDP_Domain, cfg->domain);
    ok &= freerdp_settings_set_bool(st, FreeRDP_AutoLogonEnabled, TRUE);
    ok &= freerdp_settings_set_uint32(st, FreeRDP_DesktopWidth, (UINT32)cfg->width);
    ok &= freerdp_settings_set_uint32(st, FreeRDP_DesktopHeight, (UINT32)cfg->height);
    ok &= freerdp_settings_set_uint32(st, FreeRDP_ColorDepth, 32);
    ok &= freerdp_settings_set_bool(st, FreeRDP_SoftwareGdi, TRUE);
    ok &= freerdp_settings_set_bool(st, FreeRDP_SupportGraphicsPipeline, TRUE);
    ok &= freerdp_settings_set_bool(st, FreeRDP_GfxH264, FALSE);
    ok &= freerdp_settings_set_bool(st, FreeRDP_GfxAVC444, FALSE);
    ok &= freerdp_settings_set_bool(st, FreeRDP_SupportDynamicChannels, TRUE);
    ok &= freerdp_settings_set_bool(st, FreeRDP_SupportDisplayControl, TRUE);
    ok &= freerdp_settings_set_bool(st, FreeRDP_DynamicResolutionUpdate, TRUE);
    ok &= freerdp_settings_set_bool(st, FreeRDP_RedirectClipboard, TRUE);
    ok &= freerdp_settings_set_bool(st, FreeRDP_IgnoreCertificate, TRUE);
    ok &= freerdp_settings_set_bool(st, FreeRDP_AutoReconnectionEnabled, FALSE);
    ok &= freerdp_settings_set_uint32(st, FreeRDP_KeyboardLayout, 0x409);
    ok &= freerdp_settings_set_bool(st, FreeRDP_AudioPlayback, cfg->audio ? TRUE : FALSE);
    if (cfg->drive_path && *cfg->drive_path) {
        const char *params[] = { "drive", cfg->drive_name && *cfg->drive_name ? cfg->drive_name : "Jarvis",
                                 cfg->drive_path };
        ok &= freerdp_settings_set_bool(st, FreeRDP_DeviceRedirection, TRUE);
        ok &= freerdp_settings_set_bool(st, FreeRDP_RedirectDrives, TRUE);
        ok &= freerdp_client_add_device_channel(st, 3, params);
    }
    if (!ok) return -2;
    s->stop = 0;
    if (pthread_create(&s->thread, NULL, run, s) != 0) return -3;
    s->has_thread = 1;
    return 0;
}

void jrdp_disconnect(jrdp_session *s) {
    if (!s) return;
    s->stop = 1;
    if (s->instance) (void)freerdp_abort_connect_context(s->instance->context);
    if (s->wake) (void)SetEvent(s->wake);
}

void jrdp_free(jrdp_session *s) {
    if (!s) return;
    if (s->has_thread) {
        jrdp_disconnect(s);
        pthread_join(s->thread, NULL);
        s->has_thread = 0;
    }
    if (s->instance) {
        clip_uninit(s);
        freerdp *instance = s->instance;
        freerdp_client_context_free(instance->context);
        table_drop(instance);
        s->instance = NULL;
    }
    ev *e = s->head;
    while (e) { ev *n = e->next; free(e->text); free(e); e = n; }
    if (s->local_text) { memset(s->local_text, 0, strlen(s->local_text)); free(s->local_text); }
    if (s->wake) (void)CloseHandle(s->wake);
    pthread_mutex_destroy(&s->lock);
    free(s);
}

static uint16_t clamp16(int v) { return (uint16_t)(v < 0 ? 0 : (v > 65535 ? 65535 : v)); }

void jrdp_mouse_move(jrdp_session *s, int x, int y) {
    ev *e = new_ev(EV_MOUSE);
    if (!e) return;
    e->flags = PTR_FLAGS_MOVE;
    e->x = clamp16(x); e->y = clamp16(y);
    push(s, e);
}

void jrdp_mouse_button(jrdp_session *s, int button, int down, int x, int y) {
    ev *e = new_ev(EV_MOUSE);
    if (!e) return;
    uint16_t b = button == 2 ? PTR_FLAGS_BUTTON2 : button == 3 ? PTR_FLAGS_BUTTON3 : PTR_FLAGS_BUTTON1;
    e->flags = (uint16_t)(b | (down ? PTR_FLAGS_DOWN : 0));
    e->x = clamp16(x); e->y = clamp16(y);
    push(s, e);
}

void jrdp_wheel(jrdp_session *s, int delta, int horizontal, int x, int y) {
    ev *e = new_ev(EV_MOUSE);
    if (!e) return;
    int d = delta < -255 ? -255 : (delta > 255 ? 255 : delta);
    uint16_t flags = horizontal ? PTR_FLAGS_HWHEEL : PTR_FLAGS_WHEEL;
    if (d < 0) flags |= PTR_FLAGS_WHEEL_NEGATIVE | (uint16_t)((256 + d) & 0xFF);
    else flags |= (uint16_t)(d & 0xFF);
    e->flags = flags;
    e->x = clamp16(x); e->y = clamp16(y);
    push(s, e);
}

void jrdp_key(jrdp_session *s, int scancode, int extended, int down) {
    ev *e = new_ev(EV_KEY);
    if (!e) return;
    e->code = MAKE_RDP_SCANCODE((UINT32)scancode, extended ? TRUE : FALSE);
    e->down = down;
    push(s, e);
}

void jrdp_unicode(jrdp_session *s, int codepoint, int down) {
    ev *e = new_ev(EV_UNICODE);
    if (!e) return;
    e->code = (uint32_t)codepoint;
    e->down = down;
    push(s, e);
}

void jrdp_resize(jrdp_session *s, int width, int height) {
    ev *e = new_ev(EV_RESIZE);
    if (!e) return;
    e->w = (width < 200 ? 200 : width) & ~1;
    e->h = height < 200 ? 200 : height;
    push(s, e);
}

void jrdp_clipboard_set_text(jrdp_session *s, const char *utf8) {
    ev *e = new_ev(EV_CLIP);
    if (!e) return;
    e->text = utf8 ? _strdup(utf8) : NULL;
    push(s, e);
}

uint32_t jrdp_error_auth_failed(void) { return FREERDP_ERROR_AUTHENTICATION_FAILED; }
uint32_t jrdp_error_logon_failure(void) { return FREERDP_ERROR_CONNECT_LOGON_FAILURE; }
uint32_t jrdp_error_wrong_password(void) { return FREERDP_ERROR_CONNECT_WRONG_PASSWORD; }
uint32_t jrdp_error_account_disabled(void) { return FREERDP_ERROR_CONNECT_ACCOUNT_DISABLED; }
uint32_t jrdp_error_password_expired(void) { return FREERDP_ERROR_CONNECT_PASSWORD_EXPIRED; }
uint32_t jrdp_error_connect_failed(void) { return FREERDP_ERROR_CONNECT_FAILED; }
uint32_t jrdp_error_dns_name_not_found(void) { return FREERDP_ERROR_DNS_NAME_NOT_FOUND; }
