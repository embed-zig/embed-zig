(() => {
  const bus = new WebSimBus();
  const logsEl = document.getElementById("logs");
  const container = document.getElementById("components");

  bus.setLogElement(logsEl);

  const controlsPanel = document.createElement("section");
  controlsPanel.className = "panel controls";
  container.appendChild(controlsPanel);

  const btnBoot = document.createElement("button");
  btnBoot.className = "boot-btn";
  btnBoot.textContent = "BTN_BOOT";
  controlsPanel.appendChild(btnBoot);

  const gpio = new GpioButton(bus, { pin: 0, activeLevel: "low" });
  gpio.bindElement(btnBoot);

  const ledPanel = document.createElement("section");
  ledPanel.className = "panel led-panel";
  container.appendChild(ledPanel);

  const ledCircle = document.createElement("div");
  ledCircle.className = "led";
  ledPanel.appendChild(ledCircle);

  const ledMeta = document.createElement("div");
  ledMeta.className = "led-meta";
  ledMeta.innerHTML = '<div><strong>state:</strong> <span id="led-state">off</span></div><div><strong>rgb:</strong> <span id="led-rgb">0,0,0</span></div>';
  ledPanel.appendChild(ledMeta);

  const ledStateEl = document.getElementById("led-state");
  const ledRgbEl = document.getElementById("led-rgb");

  new LedStripState(bus, {
    onChange(state) {
      const p = state.pixels[0] || { r: 0, g: 0, b: 0 };
      const on = p.r > 0 || p.g > 0 || p.b > 0;

      ledStateEl.textContent = on ? "on" : "off";
      ledRgbEl.textContent = `${p.r},${p.g},${p.b}`;

      if (!on) {
        ledCircle.classList.remove("on");
        ledCircle.style.background = "#0a0c16";
        return;
      }
      ledCircle.classList.add("on");
      ledCircle.style.background = `rgb(${p.r}, ${p.g}, ${p.b})`;
    },
  });

  const displayPanel = document.createElement("section");
  displayPanel.className = "panel display-panel";
  container.appendChild(displayPanel);

  const displayHeader = document.createElement("div");
  displayHeader.className = "display-header";
  displayHeader.innerHTML = '<div><strong>LCD</strong></div><div><strong>state:</strong> <span id="display-state">active</span> <strong>size:</strong> <span id="display-meta">320x240</span></div>';
  displayPanel.appendChild(displayHeader);

  const displayCanvasWrap = document.createElement("div");
  displayCanvasWrap.className = "display-canvas-wrap";
  displayPanel.appendChild(displayCanvasWrap);

  const displayCanvas = document.createElement("canvas");
  displayCanvas.className = "display-canvas";
  displayCanvas.width = 320;
  displayCanvas.height = 240;
  displayCanvasWrap.appendChild(displayCanvas);

  new DisplayState(bus, {
    canvas: displayCanvas,
    statusEl: document.getElementById("display-state"),
    metaEl: document.getElementById("display-meta"),
    width: 320,
    height: 240,
  });

  const wsProto = location.protocol === "https:" ? "wss" : "ws";
  bus.connect(`${wsProto}://${location.host}/ws`);
})();
