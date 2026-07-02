import { emitInputEvent, getState } from './api/client.ts';
import { openEvents, type RuntimeEvent } from './api/events.ts';
import type {
  DisplayState,
  EmitAck,
  GpioState,
  GroupedButtonState,
  LedStripState,
  SingleButtonState,
  StateResponse,
  SwitchOutputState,
} from './api/generated/types.gen';

export type DesktopInputEvent = 'press' | 'release' | 'down' | 'move' | 'up' | 'on' | 'off' | 'toggle' | 'high' | 'low';
export type DesktopEmitOptions = {
  point?: { x: number; y: number };
  buttonId?: number;
};

type GearState =
  | SingleButtonState
  | GroupedButtonState
  | LedStripState
  | SwitchOutputState
  | GpioState
  | DisplayState
  | { SingleButtonState: SingleButtonState }
  | { GroupedButtonState: GroupedButtonState }
  | { LedStripState: LedStripState }
  | { SwitchOutputState: SwitchOutputState }
  | { GpioState: GpioState }
  | { DisplayState: DisplayState };

export interface DesktopController {
  getState(): StateResponse;
  subscribe(listener: (state: StateResponse) => void): () => void;
  emit(
    gearLabel: string,
    event: DesktopInputEvent,
    options?: DesktopEmitOptions,
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
  let refreshTimer: ReturnType<typeof setTimeout> | null = null;

  async function refreshState(): Promise<void> {
    state = await getState();
    for (const listener of listeners) {
      listener(state);
    }
  }

  function scheduleRefresh(): void {
    if (refreshTimer != null) {
      clearTimeout(refreshTimer);
    }
    refreshTimer = setTimeout(() => {
      refreshTimer = null;
      void refreshState();
    }, 120);
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
    async emit(gearLabel, event, options) {
      const ack = await emitInputEvent({
        event,
        gearLabel,
        ts: now(),
        buttonId: options?.buttonId,
        x: options?.point?.x,
        y: options?.point?.y,
      });
      await refreshState();
      scheduleRefresh();
      return ack;
    },
    dispose() {
      if (refreshTimer != null) {
        clearTimeout(refreshTimer);
        refreshTimer = null;
      }
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

export function getGroupedButtonStates(state: StateResponse): GroupedButtonState[] {
  const buttons: GroupedButtonState[] = [];
  for (const gear of state.gears as GearState[]) {
    if ('GroupedButtonState' in gear) {
      buttons.push(gear.GroupedButtonState);
    } else if ('kind' in gear && gear.kind === 'grouped_button') {
      buttons.push(gear);
    }
  }
  return buttons;
}

export function getLedStripState(state: StateResponse): LedStripState | undefined {
  for (const gear of state.gears as GearState[]) {
    if ('LedStripState' in gear) return gear.LedStripState;
    if ('kind' in gear && gear.kind === 'ledstrip') return gear;
  }
  return undefined;
}

export function getSwitchOutputStates(state: StateResponse): SwitchOutputState[] {
  const outputs: SwitchOutputState[] = [];
  for (const gear of state.gears as GearState[]) {
    if ('SwitchOutputState' in gear) {
      outputs.push(gear.SwitchOutputState);
    } else if ('kind' in gear && gear.kind === 'switch_output') {
      outputs.push(gear);
    }
  }
  return outputs;
}

export function getGpioStates(state: StateResponse): GpioState[] {
  const gpios: GpioState[] = [];
  for (const gear of state.gears as GearState[]) {
    if ('GpioState' in gear) {
      gpios.push(gear.GpioState);
    } else if ('kind' in gear && gear.kind === 'gpio') {
      gpios.push(gear);
    }
  }
  return gpios;
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
