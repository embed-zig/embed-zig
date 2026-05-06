import {
  createDesktopController,
  getLedStripState,
  getSingleButtonState,
} from './desktop-core.ts';
import { getTopology } from './api/client.ts';
import type { StateResponse } from './api/generated/types.gen';

const titleEl = getElement('app-title', HTMLHeadingElement);
const descriptionEl = getElement('app-description', HTMLParagraphElement);
const stripEl = getElement('strip', HTMLDivElement);
const buttonEl = getElement('power-btn', HTMLButtonElement);

let latestState: StateResponse | null = null;

function log(message: string, data?: unknown): void {
  const line = data ? `${message} ${JSON.stringify(data, null, 2)}` : message;
  console.log(line);
}

function render(state: StateResponse): void {
  latestState = state;
  const button = getSingleButtonState(state);
  const strip = getLedStripState(state);

  buttonEl.classList.toggle('pressed', Boolean(button?.pressed));

  stripEl.innerHTML = '';
  for (const pixel of strip?.pixels ?? []) {
    const node = document.createElement('div');
    node.className = 'pixel';
    node.style.background = `rgb(${pixel.r}, ${pixel.g}, ${pixel.b})`;
    stripEl.appendChild(node);
  }
}

async function emit(event: 'press' | 'release'): Promise<void> {
  const response = await controller.emit(event);
  log('emit', response);
}

const controller = await createDesktopController({
  onEvent(event) {
    log(`sse ${event.event}`, event.data);
  },
});
const topology = await getTopology();

document.title = topology.title;
titleEl.textContent = topology.title;
descriptionEl.textContent = topology.description;

buttonEl.addEventListener('pointerdown', () => {
  void emit('press');
});

buttonEl.addEventListener('pointerup', () => {
  void emit('release');
});

buttonEl.addEventListener('pointerleave', () => {
  const pressed = latestState ? getSingleButtonState(latestState)?.pressed : undefined;
  if (pressed) {
    void emit('release');
  }
});

const initial = controller.getState();
render(initial);
log('initial state', initial);

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
