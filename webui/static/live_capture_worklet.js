// webui/static/live_capture_worklet.js
//
// Live capture in the browser: hands the mic's raw samples to live_capture.js
// in blocks of 2048. Resampling and framing happen there, where they are tested;
// this file only exists because an AudioWorklet must be loaded from a URL, and
// the page's CSP (script-src 'self') refuses the blob: URL voice.js tries first.
class JcLiveCaptureProcessor extends AudioWorkletProcessor {
  constructor() {
    super();
    this.buf = new Float32Array(2048);
    this.n = 0;
  }

  process(inputs) {
    const channel = inputs[0] && inputs[0][0];
    if (channel) {
      for (let i = 0; i < channel.length; i++) {
        this.buf[this.n++] = channel[i];
        if (this.n === this.buf.length) {
          this.port.postMessage(this.buf.slice(0));
          this.n = 0;
        }
      }
    }
    return true;
  }
}

registerProcessor('jc-live-capture', JcLiveCaptureProcessor);
