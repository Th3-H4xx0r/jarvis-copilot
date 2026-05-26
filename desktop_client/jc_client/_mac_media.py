"""Best-effort macOS microphone enablement for the embedded WebView.

WKWebView (via pywebview) needs two separate things before the voice page's
``getUserMedia`` works:

  1. **Web-layer grant.** The WKWebView UI delegate must answer the media-capture
     permission request. pywebview 6.x's BrowserDelegate doesn't implement that
     selector, so WKWebView denies by default — we add the method at runtime and
     grant it.
  2. **OS-layer (TCC) access.** The host process needs microphone permission,
     which macOS only prompts for when an ``NSMicrophoneUsageDescription`` is
     present. We inject one into the main bundle and proactively request audio
     access so the system prompt appears.

Everything here is best-effort and guarded: any failure is logged at debug and
swallowed, so a missing framework or an OS change never breaks the popup. No-op
on non-macOS.
"""
from __future__ import annotations

import logging
import sys

logger = logging.getLogger(__name__)

_USAGE = "JarvisCopilot voice mode uses the microphone to capture your speech."

# WKWebView media-capture permission selector + its Obj-C type encoding.
#   -(void)webView:(WKWebView*)wv requestMediaCapturePermissionForOrigin:(...)o
#          initiatedByFrame:(...)f type:(WKMediaCaptureType)t
#          decisionHandler:(void(^)(WKPermissionDecision))h
# Encoding: void, self(@), _cmd(:), wv(@), origin(@), frame(@), type(NSInteger q), block(@?)
_SELECTOR = b"webView:requestMediaCapturePermissionForOrigin:initiatedByFrame:type:decisionHandler:"
_SIGNATURE = b"v@:@@@q@?"
_WK_PERMISSION_GRANT = 1  # WKPermissionDecisionGrant


def enable_microphone() -> None:
    """Grant the embedded WebView microphone access (web + OS layers)."""
    if sys.platform != "darwin":
        return
    _inject_usage_description()
    _patch_webview_media_permission()
    _request_os_audio_access()


def _inject_usage_description() -> None:
    try:
        from Foundation import NSBundle
        info = NSBundle.mainBundle().infoDictionary()
        # For a non-bundled (terminal-launched) app this is a mutable dict;
        # setting the key lets macOS show the mic prompt + list us in Privacy.
        if info is not None and not info.get("NSMicrophoneUsageDescription"):
            info["NSMicrophoneUsageDescription"] = _USAGE
    except Exception as exc:
        logger.debug("mic: usage-description injection failed: %s", exc)


def _patch_webview_media_permission() -> None:
    try:
        import objc
        from webview.platforms import cocoa

        delegate_cls = cocoa.BrowserView.BrowserDelegate
        try:
            if delegate_cls.instancesRespondToSelector_(_SELECTOR):
                return  # already implemented (newer pywebview) — leave it
        except Exception:
            pass

        def _grant(self, webview, origin, frame, capture_type, decision_handler):
            # Grant mic/camera capture for our own loopback origin.
            decision_handler(_WK_PERMISSION_GRANT)

        objc.classAddMethods(delegate_cls, [
            objc.selector(_grant, selector=_SELECTOR, signature=_SIGNATURE),
        ])
        logger.debug("mic: added media-capture grant to BrowserDelegate")
    except Exception as exc:
        logger.debug("mic: webview media-permission patch failed: %s", exc)


def _request_os_audio_access() -> None:
    try:
        import AVFoundation
        AVFoundation.AVCaptureDevice.requestAccessForMediaType_completionHandler_(
            AVFoundation.AVMediaTypeAudio, lambda _granted: None,
        )
    except Exception as exc:
        # pyobjc-framework-AVFoundation may not be installed; the usage
        # description above still lets WKWebView trigger the prompt itself.
        logger.debug("mic: proactive AV audio request skipped: %s", exc)
