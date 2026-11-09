"""
JarvisCopilot Web UI -- Optional password authentication.
Off by default. Enable by setting HERMES_WEBUI_PASSWORD env var
or configuring a password in the Settings panel.
"""
import hashlib
import hmac
import http.cookies
import json
import logging
import os
import secrets
import tempfile
import threading
import time

from api.config import STATE_DIR, load_settings
import sys
import re as _re

logger = logging.getLogger(__name__)


# Default session TTL — 30 days. Kept as a module-level constant for backwards
# compatibility with downstream code and regression tests that import it.
# At runtime, prefer ``_resolve_session_ttl()`` which honours the env var and
# settings.json overrides; this constant is the floor / fallback.
SESSION_TTL = 86400 * 30  # 30 days


def _resolve_session_ttl() -> int:
    """Resolve session TTL from env > settings > default.

    Priority mirrors get_password_hash(): HERMES_WEBUI_SESSION_TTL env var
    first, then settings.json, falling back to ``SESSION_TTL`` (30 days).
    Clamped to [60s, 1 year] to prevent runaway cookies or self-lockout.
    """
    env_v = os.getenv('HERMES_WEBUI_SESSION_TTL', '').strip()
    if env_v.isdigit():
        val = int(env_v)
        if 60 <= val <= 86400 * 365:
            return val
    s = load_settings()
    v = s.get('session_ttl_seconds')
    if isinstance(v, int) and 60 <= v <= 86400 * 365:
        return v
    return SESSION_TTL


# ── Public paths (no auth required) ─────────────────────────────────────────
PUBLIC_PATHS = frozenset({
    '/login', '/health', '/favicon.ico', '/sw.js',
    '/api/auth/login', '/api/auth/status',
    # Voice-popup session bootstrap: the desktop client holds a valid session
    # value but the frameless webview can't set the cookie itself, so it hits
    # /api/auth/handoff to exchange the value for a Set-Cookie (validated below).
    '/api/auth/handoff',
    '/manifest.json', '/manifest.webmanifest',
    '/session/manifest.json', '/session/manifest.webmanifest',
    # JarvisCopilot pairing flow — must be reachable without a session so
    # a fresh device can complete the handshake.
    '/pair',
    '/api/auth/pair/claim',
    '/api/auth/pair/status',
})

COOKIE_NAME = 'hermes_session'

_SESSIONS_FILE = STATE_DIR / '.sessions.json'


def _load_sessions() -> dict[str, float]:
    """Load persisted sessions from STATE_DIR, pruning expired entries.

    Returns an empty dict on any read or parse error so startup is never
    blocked by a corrupt or missing sessions file.
    """
    try:
        if _SESSIONS_FILE.exists():
            data = json.loads(_SESSIONS_FILE.read_text(encoding='utf-8'))
            if not isinstance(data, dict):
                raise ValueError('malformed sessions file — expected dict')
            now = time.time()
            return {t: exp for t, exp in data.items()
                    if isinstance(t, str) and isinstance(exp, (int, float)) and exp > now}
    except Exception as e:
        logger.debug("Failed to load sessions file, starting fresh: %s", e)
    return {}


def _save_sessions(sessions: dict[str, float]) -> None:
    """Atomically persist sessions to STATE_DIR/.sessions.json (0600).

    Uses a temp file + os.replace() so a crash mid-write never leaves a
    truncated file.  Mirrors the same pattern as .signing_key persistence.
    """
    try:
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=STATE_DIR, suffix='.sessions.tmp')
        try:
            with os.fdopen(fd, 'w', encoding='utf-8') as f:
                json.dump(sessions, f)
            os.chmod(tmp, 0o600)
            os.replace(tmp, _SESSIONS_FILE)
        except Exception:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise
    except Exception as e:
        logger.debug("Failed to persist sessions: %s", e)


# Active sessions: token -> expiry timestamp (persisted across restarts via STATE_DIR)
_sessions = _load_sessions()

# ── Login rate limiter ──────────────────────────────────────────────────────
_LOGIN_ATTEMPTS_FILE = STATE_DIR / '.login_attempts.json'
_LOGIN_MAX_ATTEMPTS = 5
_LOGIN_WINDOW = 60  # seconds


def _load_login_attempts() -> dict[str, list[float]]:
    """Load persisted login attempts from STATE_DIR, pruning expired entries."""
    try:
        if _LOGIN_ATTEMPTS_FILE.exists():
            data = json.loads(_LOGIN_ATTEMPTS_FILE.read_text(encoding='utf-8'))
            if not isinstance(data, dict):
                raise ValueError('malformed login-attempts file — expected dict')
            now = time.time()
            attempts: dict[str, list[float]] = {}
            for ip, raw_times in data.items():
                if not isinstance(ip, str) or not isinstance(raw_times, list):
                    continue
                fresh = [
                    float(t)
                    for t in raw_times
                    if isinstance(t, (int, float)) and now - float(t) < _LOGIN_WINDOW
                ]
                if fresh:
                    attempts[ip] = fresh
            return attempts
    except Exception as e:
        logger.debug("Failed to load login attempts file, starting fresh: %s", e)
    return {}


def _save_login_attempts(attempts: dict[str, list[float]]) -> None:
    """Atomically persist login attempts to STATE_DIR/.login_attempts.json (0600)."""
    try:
        _LOGIN_ATTEMPTS_FILE.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=_LOGIN_ATTEMPTS_FILE.parent, suffix='.login_attempts.tmp')
        try:
            with os.fdopen(fd, 'w', encoding='utf-8') as f:
                json.dump(attempts, f)
            os.chmod(tmp, 0o600)
            os.replace(tmp, _LOGIN_ATTEMPTS_FILE)
        except Exception:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise
    except Exception as e:
        logger.debug("Failed to persist login attempts: %s", e)


_login_attempts = _load_login_attempts()  # ip -> [timestamp, ...]
_LOGIN_ATTEMPTS_LOCK = threading.Lock()


def _check_login_rate(ip: str) -> bool:
    """Return True if the IP is allowed to attempt login (thread-safe)."""
    with _LOGIN_ATTEMPTS_LOCK:
        now = time.time()
        attempts = _login_attempts.get(ip, [])
        # Prune old attempts
        attempts = [t for t in attempts if now - t < _LOGIN_WINDOW]
        if attempts:
            _login_attempts[ip] = attempts
        else:
            _login_attempts.pop(ip, None)
        _save_login_attempts(_login_attempts)
        return len(attempts) < _LOGIN_MAX_ATTEMPTS


def _record_login_attempt(ip: str) -> None:
    """Record a login attempt for rate limiting (thread-safe)."""
    with _LOGIN_ATTEMPTS_LOCK:
        now = time.time()
        attempts = _login_attempts.get(ip, [])
        attempts.append(now)
        _login_attempts[ip] = attempts
        _save_login_attempts(_login_attempts)


def _check_and_record_login(ip: str) -> bool:
    """Count one login/pair attempt for ``ip`` and say whether it may proceed.

    Check and record happen under one lock, so a parallel burst cannot slip past
    the limit between the two (thread-safe)."""
    with _LOGIN_ATTEMPTS_LOCK:
        now = time.time()
        attempts = [t for t in _login_attempts.get(ip, []) if now - t < _LOGIN_WINDOW]
        allowed = len(attempts) < _LOGIN_MAX_ATTEMPTS
        if allowed:
            attempts.append(now)
        _login_attempts[ip] = attempts
        _save_login_attempts(_login_attempts)
        return allowed


def _load_key(filename: str) -> bytes:
    """Load a 32-byte key from STATE_DIR, generating and persisting one if missing."""
    key_file = STATE_DIR / filename
    try:
        if key_file.exists():
            raw = key_file.read_bytes()
            if len(raw) >= 32:
                return raw[:32]
    except OSError:
        logger.debug("Failed to read key %s", filename)
    key = secrets.token_bytes(32)
    try:
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        key_file.write_bytes(key)
        key_file.chmod(0o600)
    except OSError:
        logger.debug("Failed to persist key %s", filename)
    return key


_PBKDF2_KEY_CACHE: bytes | None = None
_SIGNING_KEY_CACHE: bytes | None = None


def _pbkdf2_key() -> bytes:
    global _PBKDF2_KEY_CACHE
    if _PBKDF2_KEY_CACHE is None:
        _PBKDF2_KEY_CACHE = _load_key('.pbkdf2_key')
    return _PBKDF2_KEY_CACHE


def _signing_key() -> bytes:
    global _SIGNING_KEY_CACHE
    if _SIGNING_KEY_CACHE is None:
        _SIGNING_KEY_CACHE = _load_key('.signing_key')
    return _SIGNING_KEY_CACHE


def _hash_password(password, *, salt: bytes | None = None) -> str:
    """PBKDF2-SHA256 with 600k iterations (OWASP recommendation).
    Salt is the persisted PBKDF2 key, which is secret and unique per
    installation. This keeps the stored hash format a plain hex string
    (no format change to settings.json) while replacing the predictable
    STATE_DIR-derived salt from the original implementation.

    The *salt* parameter exists solely to support transparent migration
    of password hashes that were computed with a different key (e.g. the
    old `.signing_key`). Normal callers should never pass it.
    """
    if salt is None:
        salt = _pbkdf2_key()
    dk = hashlib.pbkdf2_hmac('sha256', password.encode(), salt, 600_000)
    return dk.hex()


_AUTH_HASH_LOCK = threading.Lock()
_AUTH_HASH_COMPUTED: bool = False
_AUTH_HASH_CACHE: str | None = None


def _invalidate_password_hash_cache() -> None:
    """Invalidate the in-process password hash cache so the next call to
    get_password_hash() re-reads from settings.json or the env var."""
    global _AUTH_HASH_COMPUTED, _AUTH_HASH_CACHE
    with _AUTH_HASH_LOCK:
        _AUTH_HASH_COMPUTED = False
        _AUTH_HASH_CACHE = None


def get_password_hash() -> str | None:
    """Return the active password hash, or None if auth is disabled.
    Priority: env var > settings.json.

    The hash is computed once and cached for the lifetime of the process.
    PBKDF2-600k takes ~1 s and is called on nearly every HTTP request via
    check_auth → is_auth_enabled, so caching avoids wasting a full second
    of CPU per request after the first one.

    Thread-safe: double-checked locking ensures that under a burst of
    concurrent requests only one thread computes PBKDF2, while the fast
    path (after initialisation) requires zero locks.
    """
    global _AUTH_HASH_COMPUTED, _AUTH_HASH_CACHE

    # Fast path — no lock needed once cache is populated.
    if _AUTH_HASH_COMPUTED:
        return _AUTH_HASH_CACHE

    with _AUTH_HASH_LOCK:
        # Re-check inside lock — another thread may have populated while
        # we were waiting to acquire.
        if _AUTH_HASH_COMPUTED:
            return _AUTH_HASH_CACHE

        env_pw = os.getenv('HERMES_WEBUI_PASSWORD', '').strip()
        if env_pw:
            result = _hash_password(env_pw)
        else:
            result = load_settings().get('password_hash') or None

        _AUTH_HASH_CACHE = result
        _AUTH_HASH_COMPUTED = True
        return result


def is_auth_enabled() -> bool:
    """True if a password is configured (env var or settings) OR if
    JarvisCopilot pairing-required mode is on. In either case, requests
    without a valid session are rejected by check_auth().
    """
    if get_password_hash() is not None:
        return True
    try:
        from api.pairing import is_pairing_required
        if is_pairing_required():
            return True
    except Exception:
        pass
    return False


def _pairing_required_safe() -> bool:
    """is_pairing_required() with a try/except so check_auth never crashes
    on a malformed settings.json."""
    try:
        from api.pairing import is_pairing_required
        return is_pairing_required()
    except Exception:
        return False


def verify_password(plain: str) -> bool:
    """Verify a plaintext password against the stored hash.

    Supports transparent migration of password hashes that were computed
    with the old `.signing_key` salt.  When the two keys differ and the
    legacy-salted hash matches, the password is transparently re-hashed
    with the current `.pbkdf2_key` and persisted to settings.json.
    """
    expected = get_password_hash()
    if not expected:
        return False
    # Fast path: current PBKDF2 key
    if hmac.compare_digest(_hash_password(plain), expected):
        return True
    # Migration: some hashes were computed with `.signing_key` before the
    # PBKDF2 key was separated.  Try the legacy salt; if it matches,
    # transparently upgrade so the next login uses the fast path.
    legacy_salt = _signing_key()
    current_salt = _pbkdf2_key()
    if legacy_salt != current_salt:
        if hmac.compare_digest(_hash_password(plain, salt=legacy_salt), expected):
            from api.config import save_settings

            save_settings({'_set_password': plain})
            # Password re-hashed and persisted to disk using the current salt.
            # Cache invalidation is handled by fix 2/3 (#2192) which adds the
            # _invalidate_password_hash_cache() call inside save_settings().
            return True
    return False


def create_session() -> str:
    """Create a new auth session. Returns signed cookie value."""
    token = secrets.token_hex(32)
    _sessions[token] = time.time() + _resolve_session_ttl()
    _save_sessions(_sessions)
    sig = hmac.new(_signing_key(), token.encode(), hashlib.sha256).hexdigest()
    return f"{token}.{sig}"


# A paired device keeps its session for as long as it keeps talking to the
# server. Without this every device (the iPhone, the Mac client, the Pod) fell
# off the bridge 30 days after pairing, with nothing on screen saying why.
_RENEW_AFTER = 86400  # rewrite a renewed expiry at most once a day


def renew_session(cookie_value: str) -> bool:
    """Slide a valid session's expiry to a full TTL from now. Returns whether it was valid."""
    if not verify_session(cookie_value):
        return False
    token = cookie_value.rsplit('.', 1)[0]
    target = time.time() + _resolve_session_ttl()
    if target - _sessions.get(token, 0) >= _RENEW_AFTER:
        _sessions[token] = target
        _save_sessions(_sessions)
    return True


def _prune_expired_sessions():
    """Remove all expired session entries to prevent unbounded memory growth."""
    now = time.time()
    expired = [t for t, exp in _sessions.items() if now > exp]
    if expired:
        for token in expired:
            _sessions.pop(token, None)
        _save_sessions(_sessions)


def verify_session(cookie_value: str) -> bool:
    """Verify a signed session cookie. Returns True if valid and not expired."""
    if not cookie_value or '.' not in cookie_value:
        return False
    _prune_expired_sessions()  # lazy cleanup on every verification attempt
    token, sig = cookie_value.rsplit('.', 1)
    full_sig = hmac.new(_signing_key(), token.encode(), hashlib.sha256).hexdigest()
    # Accept both new (64-char) and legacy (32-char truncated) signatures so
    # existing sessions survive the upgrade without a forced global logout.
    # The legacy branch can be removed once session TTLs have expired (~30 days).
    valid = hmac.compare_digest(sig, full_sig) or (
        len(sig) == 32 and hmac.compare_digest(sig, full_sig[:32])
    )
    if not valid:
        return False
    expiry = _sessions.get(token)
    if not expiry or time.time() > expiry:
        _sessions.pop(token, None)
        return False
    return True


def invalidate_session(cookie_value) -> None:
    """Remove a session token."""
    if cookie_value and '.' in cookie_value:
        token = cookie_value.rsplit('.', 1)[0]
        if token in _sessions:
            _sessions.pop(token, None)
            _save_sessions(_sessions)
            from security.events import emit
            emit("device", "session.revoked", {"session_prefix": token[:8]})


def parse_cookie(handler) -> str | None:
    """Extract the auth cookie from the request headers."""
    cookie_header = handler.headers.get('Cookie', '')
    if not cookie_header:
        return None
    cookie = http.cookies.SimpleCookie()
    try:
        cookie.load(cookie_header)
    except http.cookies.CookieError:
        return None
    morsel = cookie.get(COOKIE_NAME)
    return morsel.value if morsel else None


# ip -> last time a valid session was recorded for it (security advisor input).
_SESSION_SEEN: dict[str, float] = {}
_SESSION_SEEN_EVERY = 3600


def _note_session_seen(handler) -> None:
    """Record, at most hourly per IP, that this IP presented a valid session.

    The security advisor never auto-blocks an IP seen here in the last 7 days."""
    try:
        from security.netid import actor_for, client_ip
        ip = client_ip(handler)
        now = time.time()
        if now - _SESSION_SEEN.get(ip, 0) < _SESSION_SEEN_EVERY:
            return
        if len(_SESSION_SEEN) > 4096:
            _SESSION_SEEN.clear()
        _SESSION_SEEN[ip] = now
        from security.events import emit
        emit("device", "session.seen", actor_for(handler))
    except Exception:
        pass


def check_auth(handler, parsed) -> bool:
    """Check if request is authorized. Returns True if OK.
    If not authorized, sends 401 (API) or 302 redirect (page) and returns False."""
    if not is_auth_enabled():
        return True
    # Public paths don't require auth
    if parsed.path in PUBLIC_PATHS or parsed.path.startswith('/static/') or parsed.path.startswith('/session/static/'):
        return True
    # App-update install links: iOS's installer fetches them with no cookie, so
    # each one carries its own signed, expiring token (checked in api/app_updates.py).
    if parsed.path.startswith('/ota/') and getattr(handler, 'command', 'GET') in ('GET', 'HEAD'):
        return True
    # Check session cookie
    cookie_val = parse_cookie(handler)
    if cookie_val and verify_session(cookie_val):
        # Bump the device's last_seen so browser-paired devices (which
        # don't hold a WS bridge) still show as "online" in the Devices
        # tab. The pairing module debounces writes so this is cheap. A paired
        # device's session is renewed while it is in use.
        try:
            from api.pairing import touch_device_by_session
            if touch_device_by_session(cookie_val):
                renew_session(cookie_val)
        except Exception:
            pass
        _note_session_seen(handler)
        return True
    # Host-local carve-out for CLI/agent automation. The signing key is
    # 0600-owned by the same user the webui runs as, so a process that
    # can read it is already trusted at the OS level. Used by the
    # JarvisCopilot `devices` skill and `jarviscopilot devices invoke`
    # to drive the running webui without a paired-device cookie.
    if check_host_signature(handler):
        return True
    # Not authorized
    if parsed.path.startswith('/api/'):
        from security.events import emit
        from security.netid import actor_for
        emit("device", "auth.failed", actor_for(handler),
             reason="bad_cookie" if cookie_val else "no_cookie", path=parsed.path,
             ua=(handler.headers.get('User-Agent') or '')[:200])
        handler.send_response(401)
        handler.send_header('Content-Type', 'application/json')
        handler.end_headers()
        handler.wfile.write(b'{"error":"Authentication required"}')
    else:
        handler.send_response(302)
        # Pass the original path as ?next= so login.js redirects back after auth.
        # SECURITY/CORRECTNESS: the inner `?` and `&` MUST be percent-encoded
        # when stuffed into the outer `?next=` parameter, otherwise:
        #   (a) multi-param query strings get truncated at the first inner `&`
        #       (e.g. `/api/sessions?limit=50&offset=0` would round-trip as
        #       just `/api/sessions?limit=50` after the browser parses the
        #       outer URL — `offset=0` becomes a separate top-level query
        #       parameter that the login page ignores).
        #   (b) attacker-controlled paths could inject a second `next=`
        #       parameter; per RFC 3986 the duplicate behaviour is undefined
        #       and parsers diverge (Python's parse_qs returns last-match,
        #       URLSearchParams returns first-match), opening a query-pollution
        #       footgun even though _safeNextPath() rejects most malicious
        #       shapes downstream.
        # Encoding the entire `path?query` blob with quote(safe='/') turns
        # `?` → `%3F` and `&` → `%26`, so the outer parameter holds exactly
        # one path-with-query string and `searchParams.get('next')` returns
        # the full original URL (the browser auto-decodes once).
        # (Opus pre-release advisor finding for v0.50.258.)
        import urllib.parse as _urlparse
        _path_with_query = parsed.path or '/'
        if parsed.query:
            _path_with_query += '?' + parsed.query
        # safe='/' keeps path separators readable; everything else (including
        # `?`, `&`, `=`) gets percent-encoded.
        _next = _urlparse.quote(_path_with_query, safe='/')
        # JarvisCopilot pairing-mode redirects to /pair instead of /login.
        # If a password is ALSO configured, /login still works for password
        # auth — but pairing-mode-only installs have no password to enter.
        _login_path = 'pair' if (_pairing_required_safe()
                                 and get_password_hash() is None) else 'login'
        handler.send_header('Location', _login_path + '?next=' + _next)
        handler.end_headers()
    return False


def check_host_signature(handler) -> bool:
    """Validate an X-JC-Host-Sig HMAC for the current request.

    The protocol is jarviscopilot_host_sig; only loopback connections are honoured.

    Returns True on a fresh valid signature, False otherwise. False is
    the safe default — falling through to the normal auth flow.
    """
    try:
        peer = (handler.client_address[0] if handler.client_address else "") or ""
    except Exception:
        return False
    if peer not in ("127.0.0.1", "::1"):
        return False
    import jarviscopilot_host_sig as host_sig
    return host_sig.verify(_signing_key(), handler.command or "GET", handler.path or "/",
                           handler.headers.get(host_sig.HEADER, ""))


def _is_secure_context(handler=None) -> bool:
    """Return True if cookies should carry the Secure flag.

    Behaviour is overridable via HERMES_WEBUI_SECURE env var for
    reverse-proxy setups where TLS terminates at a frontend proxy
    (nginx, Cloudflare, etc.) and Python only sees plain HTTP.
    1/true/yes → force Secure on; 0/false/no → force Secure off.
    When unset, fall back to heuristics: direct TLS socket (getpeercert)
    or X-Forwarded-Proto header from the request.

    .. warning::
       The ``X-Forwarded-Proto`` header is only trustworthy when a
       reverse proxy (nginx, Cloudflare, etc.) is deployed in front
       of the application.  Without a proxy, any client can forge the
       header and cause the Secure flag to be set on plain HTTP.
    """
    env = os.getenv('HERMES_WEBUI_SECURE', '').strip().lower()
    if env in ('1', 'true', 'yes'):
        return True
    if env in ('0', 'false', 'no'):
        return False
    if handler is not None:
        if getattr(handler.request, 'getpeercert', None) is not None:
            return True
        if handler.headers.get('X-Forwarded-Proto', '') == 'https':
            return True
    return False


def set_auth_cookie(handler, cookie_value) -> None:
    """Set the auth cookie on the response."""
    cookie = http.cookies.SimpleCookie()
    cookie[COOKIE_NAME] = cookie_value
    cookie[COOKIE_NAME]['httponly'] = True
    cookie[COOKIE_NAME]['samesite'] = 'Lax'
    cookie[COOKIE_NAME]['path'] = '/'
    cookie[COOKIE_NAME]['max-age'] = str(_resolve_session_ttl())
    if _is_secure_context(handler):
        cookie[COOKIE_NAME]['secure'] = True
    handler.send_header('Set-Cookie', cookie[COOKIE_NAME].OutputString())


def _safe_next_path(raw: str) -> str:
    """Same-origin relative path only. Rejects open-redirects.

    Must begin with a single '/' and contain no scheme or backslash. Anything
    else (protocol-relative '//host', absolute 'https://…', a bare word, or a
    '/\\host' smuggle) falls back to the mini voice popup target so a crafted
    `next=` can't bounce the authenticated webview off-origin.
    """
    default = "/?mini=voice"
    if not raw or not raw.startswith("/") or raw.startswith("//"):
        return default
    if "://" in raw or "\\" in raw:
        return default
    return raw


def handle_auth_handoff(handler, parsed) -> bool:
    """Bootstrap a webview session from the client's existing session value.

    The desktop client already holds a valid `hermes_session` value (keyring).
    The frameless popup webview can't easily set that cookie itself, so it
    loads /api/auth/handoff?session=<value>&next=<path>; if the value is a live
    session we re-issue the cookie (Set-Cookie) and 302 to the sanitized
    `next`. An invalid/missing value 302s to /login. Always returns True
    (request fully handled). The query string carries a secret, so callers must
    keep it out of access logs (see the handler's log_message redaction)."""
    import urllib.parse as _urlparse
    qs = _urlparse.parse_qs(parsed.query or "")
    session_val = (qs.get("session", [""])[0] or "").strip()
    next_path = _safe_next_path((qs.get("next", [""])[0] or "").strip())
    if session_val and verify_session(session_val):
        handler.send_response(302)
        set_auth_cookie(handler, session_val)
        handler.send_header("Location", next_path)
        handler.end_headers()
    else:
        handler.send_response(302)
        handler.send_header("Location", "/login")
        handler.end_headers()
    return True


def clear_auth_cookie(handler) -> None:
    """Clear the auth cookie on the response."""
    cookie = http.cookies.SimpleCookie()
    cookie[COOKIE_NAME] = ''
    cookie[COOKIE_NAME]['httponly'] = True
    cookie[COOKIE_NAME]['path'] = '/'
    cookie[COOKIE_NAME]['max-age'] = '0'
    handler.send_header('Set-Cookie', cookie[COOKIE_NAME].OutputString())


def _normalize_host_port(value: str) -> tuple[str, str | None]:
    """Split a host or host:port string into (hostname, port|None).
    Handles IPv6 bracket notation, e.g. [::1]:8080."""
    value = value.strip().lower()
    if not value:
        return '', None
    if value.startswith('['):
        end = value.find(']')
        if end != -1:
            host = value[1:end]
            rest = value[end + 1 :]
            if rest.startswith(':') and rest[1:].isdigit():
                return host, rest[1:]
            return host, None
    if value.count(':') == 1:
        host, port = value.rsplit(':', 1)
        if port.isdigit():
            return host, port
    return value, None


def _ports_match(origin_scheme: str, origin_port: str | None, allowed_port: str | None) -> bool:
    """Return True when two ports should be considered equivalent, scheme-aware.

    Treats an absent port as the scheme default: port 80 for http, port 443 for https.
    Port 80 is NOT treated as equivalent to 443 (different protocols = different origins).
    """
    if origin_port == allowed_port:
        return True
    # Determine the default port for the origin's scheme
    default = '443' if origin_scheme == 'https' else '80'
    if not origin_port and allowed_port == default:
        return True
    if not allowed_port and origin_port == default:
        return True
    return False


def _allowed_public_origins() -> set[str]:
    """Parse HERMES_WEBUI_ALLOWED_ORIGINS env var (comma-separated) into a set.

    Each entry must include the scheme, e.g. https://myapp.example.com:8000.
    Entries without a scheme are silently skipped and a warning is printed.
    """
    raw = os.getenv('HERMES_WEBUI_ALLOWED_ORIGINS', '')
    result = set()
    for value in raw.split(','):
        value = value.strip().rstrip('/').lower()
        if not value:
            continue
        if not (value.startswith('http://') or value.startswith('https://')):
            import sys
            print(
                f"[webui] WARNING: HERMES_WEBUI_ALLOWED_ORIGINS entry {value!r} is missing "
                f"the scheme (expected https://hostname or http://hostname). Entry ignored.",
                flush=True, file=sys.stderr,
            )
            continue
        result.add(value)
    return result


def check_csrf(handler) -> bool:
    """Reject cross-origin POST requests. Returns True if OK."""
    origin = handler.headers.get("Origin", "")
    referer = handler.headers.get("Referer", "")
    host = handler.headers.get("Host", "")
    if not origin and not referer:
        return True  # non-browser clients (curl, agent) have no Origin
    target = origin or referer
    # Extract host:port from origin/referer
    m = _re.match(r"^https?://([^/]+)", target)
    if not m:
        return False
    origin_host = m.group(1)
    origin_scheme = m.group(0).split('://')[0].lower()  # 'http' or 'https'
    origin_name, origin_port = _normalize_host_port(origin_host)
    # Check against explicitly allowed public origins (env var)
    origin_value = m.group(0).rstrip('/').lower()
    if origin_value in _allowed_public_origins():
        return True
    # Allow same-origin against the real connection Host header.
    #
    # SECURITY: X-Forwarded-Host / X-Real-Host are client-controllable and must
    # NOT be trusted by default. Behind a Cloudflare tunnel every request appears
    # to originate from localhost, so honoring a forged X-Forwarded-Host would let
    # any internet origin pass the same-origin check (CSRF bypass). When the WebUI
    # genuinely sits behind a trusted reverse proxy that rewrites these headers,
    # the operator opts in with HERMES_WEBUI_TRUST_FORWARDED_HOST=1 (the nginx
    # vhost rendered by webui/edge strips inbound forwarded headers first, so this
    # is only ever set when a vetted proxy is in front). Public origins should be
    # whitelisted explicitly via HERMES_WEBUI_ALLOWED_ORIGINS instead.
    allowed_hosts = [host.strip()] if host.strip() else []
    if os.getenv("HERMES_WEBUI_TRUST_FORWARDED_HOST", "").strip().lower() in ("1", "true", "yes"):
        allowed_hosts.extend(
            h.strip()
            for h in [
                handler.headers.get("X-Forwarded-Host", ""),
                handler.headers.get("X-Real-Host", ""),
            ]
            if h.strip()
        )
    for allowed in allowed_hosts:
        allowed_name, allowed_port = _normalize_host_port(allowed)
        if origin_name == allowed_name and _ports_match(origin_scheme, origin_port, allowed_port):
            return True
    return False
