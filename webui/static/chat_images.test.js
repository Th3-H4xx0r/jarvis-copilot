'use strict';
// node --test webui/static/chat_images.test.js
//
// Chat images in the web UI: what a reply shows while it is still streaming
// (no half-typed path, no raw MEDIA: token), and the size a saved image's
// name carries so its tile can hold the right space before it loads.
const test = require('node:test');
const assert = require('node:assert/strict');
const C = require('./chat_images.js');

test('streaming text drops image tokens and a half-typed one', () => {
  assert.equal(C.forStreaming('Rokid: MEDIA:/root/a.jpg\nnext'), 'Rokid: \nnext');
  assert.equal(C.forStreaming('x MEDIA:/root/wor'), 'x ');
  assert.equal(C.forStreaming('see ![Cat](https://x/c.jpg) ok'), 'see  ok');
  assert.equal(C.forStreaming('see ![a](https://x/y'), 'see ');
  assert.equal(C.forStreaming('see ![a'), 'see ');
  assert.equal(C.forStreaming('end MEDI'), 'end ');
  assert.equal(C.forStreaming('plain text, MEDICAL words stay'), 'plain text, MEDICAL words stay');
  assert.equal(C.forStreaming('Wow!'), 'Wow!');
});

test('streaming text keeps code blocks literal', () => {
  const md = 'Use:\n```\nMEDIA:/a.jpg\n```\n';
  assert.equal(C.forStreaming(md), md);
  assert.equal(C.forStreaming('inline `MEDIA:/a.jpg` stays'), 'inline `MEDIA:/a.jpg` stays');
});

test('aspect comes from the saved name', () => {
  assert.deepEqual(C.aspectFromRef('/root/.jarviscopilot/webui/media/s/rokid-abc123_800x600.jpg'), { w: 800, h: 600 });
  assert.deepEqual(C.aspectFromRef('api/media?path=%2Froot%2Fm%2Fa-1f2e3d_1200x630.png'), { w: 1200, h: 630 });
  assert.equal(C.aspectFromRef('/root/workspace/lion.jpg'), null);
  assert.equal(C.aspectFromRef('https://x/a_0x10.jpg'), null);
});

test('viewer items read each image and its caption', () => {
  const imgs = [{ src: 'a.jpg', dataset: { caption: 'Rokid' }, alt: 'x' },
                { src: 'b.jpg', dataset: {}, alt: 'b.jpg' }];
  assert.deepEqual(C.viewerItems(imgs), [{ src: 'a.jpg', caption: 'Rokid' }, { src: 'b.jpg', caption: '' }]);
});
