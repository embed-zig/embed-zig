class GpioButton {
  constructor(bus, opts = {}) {
    this.bus = bus;
    this.dev = opts.dev || "gpio";
    this.pin = opts.pin || 0;
    this.vcc = opts.vcc || 3.3;
    this.activeLevel = opts.activeLevel || "low";
    this.holding = false;
    this.onStateChange = opts.onStateChange || null;
  }

  pressDown() {
    if (this.holding) return;
    this.holding = true;
    const voltage = this.activeLevel === "low" ? 0 : this.vcc;
    this.bus.send({ dev: this.dev, pin: this.pin, voltage });
    if (this.onStateChange) this.onStateChange(true);
  }

  release() {
    if (!this.holding) return;
    this.holding = false;
    const voltage = this.activeLevel === "low" ? this.vcc : 0;
    this.bus.send({ dev: this.dev, pin: this.pin, voltage });
    if (this.onStateChange) this.onStateChange(false);
  }

  bindElement(el) {
    el.addEventListener("pointerdown", (e) => {
      e.preventDefault();
      this.pressDown();
    });
    el.addEventListener("pointerup", () => this.release());
    el.addEventListener("pointercancel", () => this.release());
    el.addEventListener("pointerleave", () => this.release());
  }
}

window.GpioButton = GpioButton;
