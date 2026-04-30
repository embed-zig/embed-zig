import { emitInputEvent, getState } from './api/client.ts';
import { openEvents, type RuntimeEvent } from './api/events.ts';
import type {
  EmitAck,
  LedStripState,
  SingleButtonState,
  StateResponse,
} from './api/generated/types.gen';

export interface DesktopController {
  getState(): StateResponse;
  subscribe(listener: (state: StateResponse) => void): () => void;
  emit(event: 'press' | 'release'): Promise<EmitAck>;
  dispose(): void;
}

export interface CreateDesktopControllerOptions {
  gearLabel?: string;
  now?: () => number;
  onEvent?: (event: RuntimeEvent) => void;
}

export async function createDesktopController(
  options: CreateDesktopControllerOptions = {},
): Promise<DesktopController> {
  const gearLabel = options.gearLabel ?? 'power-btn';
  const now = options.now ?? Date.now;
  const listeners = new Set<(state: StateResponse) => void>();

  let state = await getState();
  const events = openEvents((event) => {
    options.onEvent?.(event);
    if (event.event !== 'state.snapshot') return;
    state = event.data;
    for (const listener of listeners) {
      listener(state);
    }
  });

  return {
    getState() {
      return state;
    },
    subscribe(listener) {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
    emit(event) {
      return emitInputEvent({
        event,
        gearLabel,
        ts: now(),
      });
    },
    dispose() {
      listeners.clear();
      events.abort();
    },
  };
}

export function getSingleButtonState(state: StateResponse): SingleButtonState | undefined {
  return state.gears.find((gear): gear is SingleButtonState => gear.kind === 'single_button');
}

export function getLedStripState(state: StateResponse): LedStripState | undefined {
  return state.gears.find((gear): gear is LedStripState => gear.kind === 'ledstrip');
}

export type DesktopEvent = RuntimeEvent;
