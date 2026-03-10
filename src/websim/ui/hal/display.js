class DisplayState {
  constructor(bus, opts = {}) {
    this.bus = bus;
    this.dev = opts.dev || "display";
    this.canvas = opts.canvas;
    this.ctx = this.canvas.getContext("2d");
    this.statusEl = opts.statusEl || null;
    this.metaEl = opts.metaEl || null;
    this.width = opts.width || this.canvas.width || 320;
    this.height = opts.height || this.canvas.height || 240;
    this.enabled = true;
    this.sleeping = false;
    this.imageData = this.ctx.createImageData(this.width, this.height);

    this.bus.on(this.dev, (msg) => this.onMessage(msg));
    this.renderStatus();
  }

  onMessage(msg) {
    if (msg.kind === "state") {
      this.width = msg.width || this.width;
      this.height = msg.height || this.height;
      this.enabled = msg.enabled !== false;
      this.sleeping = msg.sleeping === true;
      this.ensureSize();
      this.renderStatus();
      return;
    }

    if (msg.kind === "frame" && msg.format === "rgb565le" && msg.pixels_b64) {
      this.width = msg.width || this.width;
      this.height = msg.height || this.height;
      this.ensureSize();
      this.blitRgb565(msg);
      this.renderStatus();
    }
  }

  ensureSize() {
    if (this.canvas.width !== this.width) this.canvas.width = this.width;
    if (this.canvas.height !== this.height) this.canvas.height = this.height;
    const needed = this.width * this.height * 4;
    if (!this.imageData || this.imageData.data.length !== needed) {
      this.imageData = this.ctx.createImageData(this.width, this.height);
    }
  }

  blitRgb565(msg) {
    const x = msg.x || 0;
    const y = msg.y || 0;
    const w = msg.w || this.width;
    const h = msg.h || this.height;
    const raw = this.decodeBase64(msg.pixels_b64);
    const dst = this.imageData.data;

    for (let row = 0; row < h; row += 1) {
      for (let col = 0; col < w; col += 1) {
        const srcIndex = (row * w + col) * 2;
        const px = raw[srcIndex] | (raw[srcIndex + 1] << 8);
        const r5 = (px >> 11) & 0x1f;
        const g6 = (px >> 5) & 0x3f;
        const b5 = px & 0x1f;
        const di = ((y + row) * this.width + (x + col)) * 4;
        dst[di] = (r5 << 3) | (r5 >> 2);
        dst[di + 1] = (g6 << 2) | (g6 >> 4);
        dst[di + 2] = (b5 << 3) | (b5 >> 2);
        dst[di + 3] = 255;
      }
    }

    this.ctx.putImageData(this.imageData, 0, 0);
  }

  decodeBase64(value) {
    const binary = atob(value);
    const out = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i += 1) out[i] = binary.charCodeAt(i);
    return out;
  }

  renderStatus() {
    if (this.statusEl) {
      this.statusEl.textContent = !this.enabled ? "disabled" : this.sleeping ? "sleeping" : "active";
    }
    if (this.metaEl) {
      this.metaEl.textContent = `${this.width}x${this.height}`;
    }
    this.canvas.classList.toggle("display-sleeping", !this.enabled || this.sleeping);
  }
}

window.DisplayState = DisplayState;
