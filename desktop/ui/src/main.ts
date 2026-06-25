import {
  createDesktopController,
  getDisplayStates,
  getGroupedButtonStates,
  getLedStripState,
  getSingleButtonStates,
  getSwitchOutputStates,
} from './desktop-core.ts';
import { getTopology } from './api/client.ts';
import type { GearTopology, StateResponse } from './api/generated/types.gen';

const titleEl = getElement('app-title', HTMLHeadingElement);
const descriptionEl = getElement('app-description', HTMLParagraphElement);
const gearsEl = getElement('gears', HTMLDivElement);

let latestState: StateResponse | null = null;
const buttonEls = new Map<string, HTMLButtonElement>();
const groupedButtonEls = new Map<string, HTMLButtonElement[]>();
const switchOutputEls = new Map<string, HTMLButtonElement>();
const displayCanvases = new Map<string, HTMLCanvasElement>();

function log(message: string, data?: unknown): void {
  const line = data ? `${message} ${JSON.stringify(data, null, 2)}` : message;
  console.log(line);
}

function subscribeBackendLogs(): void {
  const source = new EventSource('/logs');
  source.addEventListener('log', (event) => {
    if (event instanceof MessageEvent) console.log(event.data);
  });
  source.onerror = () => {
    console.error('desktop log stream disconnected');
  };
}

function render(state: StateResponse): void {
  latestState = state;
  const buttons = getSingleButtonStates(state);
  const groupedButtons = getGroupedButtonStates(state);
  const strip = getLedStripState(state);
  const switchOutputs = getSwitchOutputStates(state);
  const displays = getDisplayStates(state);

  for (const button of buttons) {
    const node = buttonEls.get(button.label);
    node?.classList.toggle('pressed', button.pressed);
  }

  for (const group of groupedButtons) {
    const nodes = groupedButtonEls.get(group.label) ?? [];
    nodes.forEach((node, id) => {
      node.classList.toggle('pressed', group.pressed_button_id === id);
    });
  }

  for (const output of switchOutputs) {
    const node = switchOutputEls.get(output.label);
    if (!node) continue;
    node.classList.toggle('enabled', output.enabled);
    node.setAttribute('aria-checked', String(output.enabled));
  }

  const stripEl = document.getElementById('strip');
  if (stripEl instanceof HTMLDivElement) {
    stripEl.innerHTML = '';
    for (const pixel of strip?.pixels ?? []) {
      const node = document.createElement('div');
      node.className = 'pixel';
      node.style.background = `rgb(${pixel.r}, ${pixel.g}, ${pixel.b})`;
      stripEl.appendChild(node);
    }
  }

  for (const display of displays) {
    const canvas = displayCanvases.get(display.label);
    if (!canvas) continue;
    drawDisplay(canvas, display);
  }
}

async function emit(gearLabel: string, event: 'press' | 'release'): Promise<void> {
  await controller.emit(gearLabel, event);
}

async function emitTouch(
  gearLabel: string,
  event: 'down' | 'move' | 'up',
  point?: { x: number; y: number },
): Promise<void> {
  await controller.emit(gearLabel, event, { point });
}

async function emitGroupedButton(gearLabel: string, event: 'press' | 'release', buttonId: number): Promise<void> {
  await controller.emit(gearLabel, event, { buttonId });
}

async function emitSwitchOutput(gearLabel: string, event: 'toggle' | 'on' | 'off'): Promise<void> {
  await controller.emit(gearLabel, event);
}

const controller = await createDesktopController({
  onEvent(event) {
    if (event.event === 'display.updated') {
      const canvas = displayCanvases.get(event.data.label);
      if (canvas) drawDisplayUpdate(canvas, event.data);
    }
  },
});
const topology = await getTopology();
subscribeBackendLogs();

document.title = topology.title;
titleEl.textContent = topology.title;
descriptionEl.textContent = topology.description;

buildGearUi();

const initial = controller.getState();
render(initial);

controller.subscribe((state) => {
  render(state);
});

function getElement<T extends typeof Element>(id: string, Ctor: T): InstanceType<T> {
  const node = document.getElementById(id);
  if (!(node instanceof Ctor)) {
    throw new Error(`Missing #${id} element`);
  }
  return node as InstanceType<T>;
}

function buildGearUi(): void {
  gearsEl.innerHTML = '';
  buttonEls.clear();
  groupedButtonEls.clear();
  switchOutputEls.clear();
  displayCanvases.clear();

  for (const gear of topology.gears) {
    if (gear.kind === 'single_button') {
      const button = document.createElement('button');
      button.className = 'button';
      button.type = 'button';
      button.textContent = formatGearLabel(gear);
      button.addEventListener('pointerdown', () => {
        void emit(gear.label, 'press');
      });
      button.addEventListener('pointerup', () => {
        void emit(gear.label, 'release');
      });
      button.addEventListener('pointerleave', () => {
        const pressed = latestState
          ? getSingleButtonStates(latestState).find((item) => item.label === gear.label)?.pressed
          : undefined;
        if (pressed) void emit(gear.label, 'release');
      });
      buttonEls.set(gear.label, button);
      gearsEl.appendChild(wrapPanel(button));
      continue;
    }

    if (gear.kind === 'grouped_button') {
      const group = document.createElement('div');
      group.className = 'grouped-button';

      const label = document.createElement('div');
      label.className = 'grouped-button-label';
      label.textContent = formatGearLabel(gear);
      group.appendChild(label);

      const grid = document.createElement('div');
      grid.className = 'grouped-button-grid';
      const buttons: HTMLButtonElement[] = [];
      for (let id = 0; id < (gear.button_count ?? 0); id += 1) {
        const button = document.createElement('button');
        button.className = 'button grouped-button-key';
        button.type = 'button';
        button.textContent = formatGroupedButtonLabel(gear, id);
        button.title = `${gear.label}:${id}`;
        button.addEventListener('pointerdown', () => {
          void emitGroupedButton(gear.label, 'press', id);
        });
        button.addEventListener('pointerup', () => {
          void emitGroupedButton(gear.label, 'release', id);
        });
        button.addEventListener('pointerleave', () => {
          const pressed = latestState
            ? getGroupedButtonStates(latestState).find((item) => item.label === gear.label)?.pressed_button_id === id
            : false;
          if (pressed) void emitGroupedButton(gear.label, 'release', id);
        });
        buttons.push(button);
        grid.appendChild(button);
      }
      groupedButtonEls.set(gear.label, buttons);
      group.appendChild(grid);
      gearsEl.appendChild(wrapPanel(group));
      continue;
    }

    if (gear.kind === 'switch_output') {
      const toggle = document.createElement('button');
      toggle.className = 'switch-output';
      toggle.type = 'button';
      toggle.setAttribute('role', 'switch');
      toggle.setAttribute('aria-checked', 'false');
      toggle.title = gear.label;

      const text = document.createElement('span');
      text.className = 'switch-output-label';
      text.textContent = formatGearLabel(gear);
      toggle.appendChild(text);

      const track = document.createElement('span');
      track.className = 'switch-output-track';
      track.setAttribute('aria-hidden', 'true');
      const thumb = document.createElement('span');
      thumb.className = 'switch-output-thumb';
      track.appendChild(thumb);
      toggle.appendChild(track);

      toggle.addEventListener('click', () => {
        void emitSwitchOutput(gear.label, 'toggle');
      });
      switchOutputEls.set(gear.label, toggle);
      gearsEl.appendChild(wrapPanel(toggle));
      continue;
    }

    if (gear.kind === 'ledstrip') {
      const strip = document.createElement('div');
      strip.id = 'strip';
      strip.className = 'strip';
      gearsEl.appendChild(wrapPanel(strip));
      continue;
    }

    if (gear.kind === 'display') {
      const touchLabel = topology.gears.find((candidate) => {
        return candidate.kind === 'touch' && candidate.target === gear.label;
      })?.label;
      if (gear.width == null || gear.height == null) continue;
      const canvas = document.createElement('canvas');
      canvas.className = 'display';
      canvas.width = gear.width;
      canvas.height = gear.height;
      syncDisplayCssSize(canvas);
      if (touchLabel) bindDisplayTouch(canvas, touchLabel);
      displayCanvases.set(gear.label, canvas);
      gearsEl.appendChild(wrapPanel(canvas));
    }
  }
}

function wrapPanel(child: HTMLElement): HTMLDivElement {
  const panel = document.createElement('div');
  panel.className = 'panel';
  panel.appendChild(child);
  return panel;
}

function formatLabel(label: string): string {
  return label
    .split('_')
    .map((part) => `${part.slice(0, 1).toUpperCase()}${part.slice(1)}`)
    .join(' ');
}

function formatGearLabel(gear: GearTopology): string {
  return gear.metadata?.label_text ?? formatLabel(gear.label);
}

function formatGroupedButtonLabel(gear: GearTopology, buttonId: number): string {
  return gear.metadata?.item_label_texts?.[buttonId] ?? String(buttonId);
}

function drawDisplay(canvas: HTMLCanvasElement, display: ReturnType<typeof getDisplayStates>[number]): void {
  if (canvas.width !== display.width) canvas.width = display.width;
  if (canvas.height !== display.height) canvas.height = display.height;
  syncDisplayCssSize(canvas);

  drawRgb888(canvas, 0, 0, display.width, display.height, display.pixels);
}

function syncDisplayCssSize(canvas: HTMLCanvasElement): void {
  canvas.style.width = `${canvas.width}px`;
  canvas.style.height = `${canvas.height}px`;
}

function drawDisplayUpdate(
  canvas: HTMLCanvasElement,
  update: { x: number; y: number; w: number; h: number; pixels: string },
): void {
  drawRgb888(canvas, update.x, update.y, update.w, update.h, update.pixels);
}

function drawRgb888(canvas: HTMLCanvasElement, x: number, y: number, w: number, h: number, pixels: string): void {
  const ctx = canvas.getContext('2d');
  if (!ctx) return;

  const rgb = decodeBase64(pixels);
  const image = ctx.createImageData(w, h);
  const count = Math.min(w * h, Math.floor(rgb.length / 3));
  for (let index = 0; index < count; index += 1) {
    const rgbBase = index * 3;
    const base = index * 4;
    image.data[base] = rgb[rgbBase] ?? 0;
    image.data[base + 1] = rgb[rgbBase + 1] ?? 0;
    image.data[base + 2] = rgb[rgbBase + 2] ?? 0;
    image.data[base + 3] = 255;
  }
  ctx.putImageData(image, x, y);
}

function decodeBase64(value: string): Uint8Array {
  const binary = atob(value);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) {
    bytes[index] = binary.charCodeAt(index);
  }
  return bytes;
}

function bindDisplayTouch(canvas: HTMLCanvasElement, touchLabel: string): void {
  let activePointer: number | null = null;

  canvas.addEventListener('pointerdown', (event) => {
    activePointer = event.pointerId;
    canvas.setPointerCapture(event.pointerId);
    void emitTouch(touchLabel, 'down', canvasPoint(canvas, event));
  });
  canvas.addEventListener('pointermove', (event) => {
    if (activePointer !== event.pointerId) return;
    void emitTouch(touchLabel, 'move', canvasPoint(canvas, event));
  });
  canvas.addEventListener('pointerup', (event) => {
    if (activePointer !== event.pointerId) return;
    activePointer = null;
    canvas.releasePointerCapture(event.pointerId);
    void emitTouch(touchLabel, 'up');
  });
  canvas.addEventListener('pointercancel', (event) => {
    if (activePointer !== event.pointerId) return;
    activePointer = null;
    canvas.releasePointerCapture(event.pointerId);
    void emitTouch(touchLabel, 'up');
  });
}

function canvasPoint(canvas: HTMLCanvasElement, event: PointerEvent): { x: number; y: number } {
  const rect = canvas.getBoundingClientRect();
  const x = ((event.clientX - rect.left) / rect.width) * canvas.width;
  const y = ((event.clientY - rect.top) / rect.height) * canvas.height;
  return {
    x: Math.max(0, Math.min(canvas.width - 1, Math.round(x))),
    y: Math.max(0, Math.min(canvas.height - 1, Math.round(y))),
  };
}
