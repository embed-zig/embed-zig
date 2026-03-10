class LedStripState {
  constructor(bus, opts = {}) {
    this.bus = bus;
    this.dev = opts.dev || "led_strip";
    this.pixels = [];
    this.onChange = opts.onChange || null;

    this.bus.on(this.dev, (msg) => {
      if (msg.pixels) {
        this.pixels = msg.pixels;
        if (this.onChange) this.onChange(this);
      }
    });
  }
}

window.LedStripState = LedStripState;
