import {
  createDesktopController,
  getDisplayStates,
  getLedStripState,
  getSingleButtonStates,
} from './desktop-core.ts';
import { getTopology } from './api/client.ts';
import type { StateResponse } from './api/generated/types.gen';

const titleEl = getElement('app-title', HTMLHeadingElement);
const descriptionEl = getElement('app-description', HTMLParagraphElement);
const gearsEl = getElement('gears', HTMLDivElement);

let latestState: StateResponse | null = null;
const buttonEls = new Map<string, HTMLButtonElement>();
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
  const strip = getLedStripState(state);
  const displays = getDisplayStates(state);

  for (const button of buttons) {
    const node = buttonEls.get(button.label);
    node?.classList.toggle('pressed', button.pressed);
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
  await controller.emit(gearLabel, event, point);
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
  displayCanvases.clear();

  for (const gear of topology.gears) {
    if (gear.kind === 'single_button') {
      const button = document.createElement('button');
      button.className = 'button';
      button.type = 'button';
      button.textContent = formatLabel(gear.label);
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

function drawDisplay(canvas: HTMLCanvasElement, display: ReturnType<typeof getDisplayStates>[number]): void {
  if (canvas.width !== display.width) canvas.width = display.width;
  if (canvas.height !== display.height) canvas.height = display.height;

  drawRgb888(canvas, 0, 0, display.width, display.height, display.pixels);
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
