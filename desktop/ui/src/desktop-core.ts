import { emitInputEvent, getState } from './api/client.ts';
import { openEvents, type RuntimeEvent } from './api/events.ts';
import type {
  EmitAck,
  LedStripState,
  SingleButtonState,
  StateResponse,
} from './api/generated/types.gen';

type GearState =
  | SingleButtonState
  | LedStripState
  | { SingleButtonState: SingleButtonState }
  | { LedStripState: LedStripState };

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
  const now = options.now ?? Date.now;
  const listeners = new Set<(state: StateResponse) => void>();

  let state = await getState();
  const gearLabel = options.gearLabel ?? getSingleButtonState(state)?.label;
  if (!gearLabel) {
    throw new Error('No single button gear is available.');
  }

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
  for (const gear of state.gears as GearState[]) {
    if ('SingleButtonState' in gear) return gear.SingleButtonState;
    if ('kind' in gear && gear.kind === 'single_button') return gear;
  }
  return undefined;
}

export function getLedStripState(state: StateResponse): LedStripState | undefined {
  for (const gear of state.gears as GearState[]) {
    if ('LedStripState' in gear) return gear.LedStripState;
    if ('kind' in gear && gear.kind === 'ledstrip') return gear;
  }
  return undefined;
}

export type DesktopEvent = RuntimeEvent;
