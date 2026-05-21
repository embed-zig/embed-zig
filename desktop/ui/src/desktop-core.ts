import { emitInputEvent, getState } from './api/client.ts';
import { openEvents, type RuntimeEvent } from './api/events.ts';
import type {
  DisplayState,
  EmitAck,
  LedStripState,
  SingleButtonState,
  StateResponse,
} from './api/generated/types.gen';

export type DesktopInputEvent = 'press' | 'release' | 'down' | 'move' | 'up';

type GearState =
  | SingleButtonState
  | LedStripState
  | DisplayState
  | { SingleButtonState: SingleButtonState }
  | { LedStripState: LedStripState }
  | { DisplayState: DisplayState };

export interface DesktopController {
  getState(): StateResponse;
  subscribe(listener: (state: StateResponse) => void): () => void;
  emit(
    gearLabel: string,
    event: DesktopInputEvent,
    point?: { x: number; y: number },
  ): Promise<EmitAck>;
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
    emit(gearLabel, event, point) {
      return emitInputEvent({
        event,
        gearLabel,
        ts: now(),
        x: point?.x,
        y: point?.y,
      });
    },
    dispose() {
      listeners.clear();
      events.abort();
    },
  };
}

export function getSingleButtonStates(state: StateResponse): SingleButtonState[] {
  const buttons: SingleButtonState[] = [];
  for (const gear of state.gears as GearState[]) {
    if ('SingleButtonState' in gear) {
      buttons.push(gear.SingleButtonState);
    } else if ('kind' in gear && gear.kind === 'single_button') {
      buttons.push(gear);
    }
  }
  return buttons;
}

export function getSingleButtonState(state: StateResponse): SingleButtonState | undefined {
  return getSingleButtonStates(state)[0];
}

export function getLedStripState(state: StateResponse): LedStripState | undefined {
  for (const gear of state.gears as GearState[]) {
    if ('LedStripState' in gear) return gear.LedStripState;
    if ('kind' in gear && gear.kind === 'ledstrip') return gear;
  }
  return undefined;
}

export function getDisplayStates(state: StateResponse): DisplayState[] {
  const displays: DisplayState[] = [];
  for (const gear of state.gears as GearState[]) {
    if ('DisplayState' in gear) {
      displays.push(gear.DisplayState);
    } else if ('kind' in gear && gear.kind === 'display') {
      displays.push(gear);
    }
  }
  return displays;
}

export type DesktopEvent = RuntimeEvent;
