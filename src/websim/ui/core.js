class WebSimBus {
  constructor() {
    this._handlers = {};
    this._ws = null;
    this._logEl = null;
  }

  connect(url) {
    this._ws = new WebSocket(url);
    this._ws.addEventListener("open", () => this._log("[ws] connected"));
    this._ws.addEventListener("close", () => this._log("[ws] closed"));
    this._ws.addEventListener("message", (e) => {
      const raw = String(e.data);
      this._log(`[recv] ${this._formatLogPayload(raw)}`);
      try {
        const msg = JSON.parse(raw);
        if (msg.dev && this._handlers[msg.dev]) {
          this._handlers[msg.dev].forEach((h) => h(msg));
        }
      } catch (_) {}
    });
  }

  on(dev, handler) {
    if (!this._handlers[dev]) this._handlers[dev] = [];
    this._handlers[dev].push(handler);
  }

  send(msg) {
    if (!this._ws || this._ws.readyState !== WebSocket.OPEN) return;
    const raw = JSON.stringify(msg);
    this._log(`[send] ${this._formatLogPayload(raw)}`);
    this._ws.send(raw);
  }

  setLogElement(el) {
    this._logEl = el;
  }

  _log(line) {
    if (!this._logEl) return;
    this._logEl.textContent += `${line}\n`;
    this._logEl.scrollTop = this._logEl.scrollHeight;
  }

  _formatLogPayload(raw) {
    try {
      return JSON.stringify(this._summarizeValue(JSON.parse(raw)));
    } catch (_) {
      return this._summarizeString(raw);
    }
  }

  _summarizeValue(value) {
    if (typeof value === "string") return this._summarizeString(value);

    if (Array.isArray(value)) {
      if (value.length > 16) return `[array len=${value.length}]`;
      return value.map((item) => this._summarizeValue(item));
    }

    if (value && typeof value === "object") {
      const out = {};
      for (const [key, item] of Object.entries(value)) {
        if (typeof item === "string" && this._looksLikeBase64Field(key, item)) {
          out[key] = `[base64 len=${item.length} preview=${item.slice(0, 24)}...]`;
          continue;
        }
        if (typeof item === "string" && this._looksLikeHex(item)) {
          out[key] = `[hex len=${item.length} preview=${item.slice(0, 24)}...]`;
          continue;
        }
        out[key] = this._summarizeValue(item);
      }
      return out;
    }

    return value;
  }

  _summarizeString(value) {
    if (this._looksLikeHex(value)) {
      return `[hex len=${value.length} preview=${value.slice(0, 24)}...]`;
    }
    if (this._looksLikeBase64(value)) {
      return `[base64 len=${value.length} preview=${value.slice(0, 24)}...]`;
    }
    if (value.length > 240) {
      return `${value.slice(0, 240)}... [len=${value.length}]`;
    }
    return value;
  }

  _looksLikeBase64Field(key, value) {
    return key.endsWith("_b64") || key === "data" || this._looksLikeBase64(value);
  }

  _looksLikeBase64(value) {
    return value.length > 128 && /^[A-Za-z0-9+/=]+$/.test(value);
  }

  _looksLikeHex(value) {
    return value.length > 64 && /^([0-9a-fA-F]{2})+$/.test(value);
  }
}

window.WebSimBus = WebSimBus;
