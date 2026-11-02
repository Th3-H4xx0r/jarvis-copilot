'use strict';
// Chat images in the web UI — the parts that live outside renderMd():
//
//  * forStreaming(text): what a reply shows while it is still streaming. Image
//    tokens (MEDIA:… and ![…](…)) and a half-typed one at the end are left out,
//    so a raw path never flashes; the images appear in place when the reply is
//    done (renderMd draws the finished text).
//  * aspectFromRef(ref): a saved chat image is named …_<W>x<H>.<ext>
//    (agent/chat_media.py), so its tile can reserve the right space.
//  * the viewer: tap an image → full screen, ←/→ through every image of that
//    reply, caption, download, Esc.
//  * a picture that fails to load becomes an "Image unavailable · Retry" tile.
(function (root) {
  const FENCE = /^\s*(```|~~~)/;
  const TOKENS = /MEDIA:[^\s)\]]+|!\[[^\]\n]*\]\([^)\s]*\)/g;
  const PARTIAL = /(?:(^|\s)M(?:E(?:D(?:I(?:A(?::\S*)?)?)?)?)?|!\[[^\]\n]*(?:\]\([^)\s]*)?)$/;

  function _stripLine(line) {
    // Keep inline `code` as written; strip tokens everywhere else.
    return line.split(/(`[^`]*`)/).map((part, i) => (i % 2 ? part : part.replace(TOKENS, ''))).join('');
  }

  function forStreaming(text) {
    const lines = String(text || '').split('\n');
    let inCode = false;
    for (let i = 0; i < lines.length; i++) {
      if (FENCE.test(lines[i])) { inCode = !inCode; continue; }
      if (!inCode) lines[i] = _stripLine(lines[i]);
    }
    let out = lines.join('\n');
    // A half-typed token at the very end (not inside code) waits until it is whole.
    const last = lines[lines.length - 1] || '';
    const inInlineCode = (last.split('`').length - 1) % 2 === 1;
    if (!inCode && !inInlineCode) out = out.replace(PARTIAL, (m, lead) => (lead || ''));
    return out;
  }

  function aspectFromRef(ref) {
    let s = String(ref || '');
    const q = s.indexOf('path=');
    if (q >= 0) {
      try { s = decodeURIComponent(s.slice(q + 5).split('&')[0]); } catch (_) { /* keep raw */ }
    }
    const m = s.split('?')[0].match(/_(\d+)x(\d+)\.[A-Za-z0-9]+$/);
    if (!m) return null;
    const w = +m[1], h = +m[2];
    return w > 0 && h > 0 ? { w, h } : null;
  }

  function viewerItems(imgs) {
    return Array.from(imgs || []).map(img => ({
      src: img.src, caption: (img.dataset && img.dataset.caption) || '',
    }));
  }

  // ── viewer ───────────────────────────────────────────────────────────────
  function openViewer(items, start) {
    if (!items || !items.length || typeof document === 'undefined') return;
    let i = Math.max(0, Math.min(start || 0, items.length - 1));
    const lb = document.createElement('div');
    lb.className = 'img-lightbox chat-viewer';
    lb.setAttribute('role', 'dialog');
    lb.setAttribute('aria-modal', 'true');
    lb.innerHTML =
      '<figure class="chat-viewer-fig"><img alt=""><figcaption></figcaption></figure>' +
      '<div class="chat-viewer-bar"><span class="chat-viewer-count"></span>' +
      '<a class="chat-viewer-btn chat-viewer-download" download title="Download" aria-label="Download">⤓</a>' +
      '<button type="button" class="chat-viewer-btn img-lightbox-close" aria-label="Close">×</button></div>' +
      (items.length > 1
        ? '<button type="button" class="chat-viewer-nav prev" aria-label="Previous image">‹</button>' +
          '<button type="button" class="chat-viewer-nav next" aria-label="Next image">›</button>'
        : '');
    const img = lb.querySelector('img'), cap = lb.querySelector('figcaption');
    const count = lb.querySelector('.chat-viewer-count'), dl = lb.querySelector('.chat-viewer-download');
    const show = () => {
      const it = items[i];
      img.src = it.src;
      img.alt = it.caption || 'Image';
      cap.textContent = it.caption || '';
      cap.hidden = !it.caption;
      count.textContent = items.length > 1 ? `${i + 1} / ${items.length}` : '';
      dl.href = /[?&]path=/.test(it.src) ? it.src + '&download=1' : it.src;
      lb.setAttribute('aria-label', it.caption || 'Image');
    };
    const go = d => { i = (i + d + items.length) % items.length; show(); };
    const onKey = e => {
      if (e.key === 'Escape') close();
      else if (e.key === 'ArrowLeft' && items.length > 1) go(-1);
      else if (e.key === 'ArrowRight' && items.length > 1) go(1);
    };
    const close = () => {
      document.removeEventListener('keydown', onKey);
      lb.remove();
    };
    lb.addEventListener('click', e => {
      if (e.target.closest('.prev')) return go(-1);
      if (e.target.closest('.next')) return go(1);
      if (e.target.closest('.img-lightbox-close')) return close();
      if (e.target.closest('.chat-viewer-fig img, .chat-viewer-download, figcaption')) return;
      close();
    });
    // Swipe on touch screens.
    let x0 = null;
    lb.addEventListener('touchstart', e => { x0 = e.touches[0].clientX; }, { passive: true });
    lb.addEventListener('touchend', e => {
      if (x0 === null || items.length < 2) return;
      const dx = e.changedTouches[0].clientX - x0;
      x0 = null;
      if (Math.abs(dx) > 50) go(dx < 0 ? 1 : -1);
    });
    document.addEventListener('keydown', onKey);
    document.body.appendChild(lb);
    show();
    lb.querySelector('.img-lightbox-close').focus();
  }

  // The images a tap should page through: every chat image of that reply
  // (or of that job card).
  function openFrom(img) {
    const scope = img.closest('.msg-body, .harness-job-thumbs') || img.parentElement;
    const all = [...scope.querySelectorAll('img.msg-media-img')];
    openViewer(viewerItems(all), Math.max(0, all.indexOf(img)));
  }

  // ── loading + failure ────────────────────────────────────────────────────
  function _onLoad(e) {
    const img = e.target;
    if (img && img.classList && img.classList.contains('msg-media-img')) img.classList.add('is-loaded');
  }

  function _onError(e) {
    const img = e.target;
    if (!img || !img.classList || !img.classList.contains('msg-media-img') || img.dataset.failed) return;
    img.dataset.failed = '1';
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'chat-img-failed';
    btn.textContent = 'Image unavailable · Retry';
    if (img.getAttribute('style')) btn.setAttribute('style', img.getAttribute('style'));
    btn.addEventListener('click', ev => {
      ev.stopPropagation();
      const src = (img.getAttribute('src') || '').replace(/[?&]r=\d+$/, '');
      delete img.dataset.failed;
      img.setAttribute('src', src + (src.includes('?') ? '&' : '?') + 'r=' + Date.now());
      btn.replaceWith(img);
    });
    img.replaceWith(btn);
  }

  if (typeof document !== 'undefined' && document.addEventListener) {
    document.addEventListener('load', _onLoad, true);
    document.addEventListener('error', _onError, true);
  }

  const api = { forStreaming, aspectFromRef, viewerItems, openViewer, openFrom };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else root.ChatImages = api;
})(typeof window !== 'undefined' ? window : this);
