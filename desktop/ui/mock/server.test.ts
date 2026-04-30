import { afterAll, beforeAll, expect, test } from 'bun:test';

import { emitInputEvent, getState } from '../src/api/client.ts';
import { client } from '../src/api/generated/client.gen.ts';
import { openEvents, type RuntimeEvent } from '../src/api/events.ts';
import { createMockServer, type MockServer } from './server.ts';

let server: MockServer;

beforeAll(() => {
  server = createMockServer({
    animationIntervalMs: 20,
  });
  client.setConfig({
    baseUrl: `http://127.0.0.1:${server.port}`,
  });
});

afterAll(async () => {
  await server.stop(true);
});

test('SSE publishes ledstrip refresh events after emit', async () => {
  const snapshots: Extract<RuntimeEvent, { event: 'state.snapshot' }>[] = [];
  const refreshes: Extract<RuntimeEvent, { event: 'ledstrip.refreshed' }>[] = [];
  const events: RuntimeEvent[] = [];
  const initialSnapshot = deferred<Extract<RuntimeEvent, { event: 'state.snapshot' }>>();
  const secondRefresh = deferred<Extract<RuntimeEvent, { event: 'ledstrip.refreshed' }>>();

  const controller = openEvents((event) => {
    events.push(event);

    if (event.event === 'state.snapshot' && !initialSnapshot.settled) {
      initialSnapshot.resolve(event);
    }

    if (event.event === 'state.snapshot') {
      snapshots.push(event);
    }

    if (event.event === 'ledstrip.refreshed') {
      refreshes.push(event);
      if (refreshes.length >= 2 && !secondRefresh.settled) {
        secondRefresh.resolve(event);
      }
    }
  });

  try {
    await withTimeout(initialSnapshot.promise, 1_000, 'Timed out waiting for initial SSE snapshot.');
    await withTimeout(secondRefresh.promise, 1_000, 'Timed out waiting for animated ledstrip SSE events.');

    expect(refreshes[0]?.data.label).toBe('strip');
    expect(refreshes[0]?.data.refresh_count).toBeGreaterThanOrEqual(2);
    expect(refreshes[1]?.data.refresh_count).toBe(refreshes[0]!.data.refresh_count + 1);
    expect(samePixels(refreshes[0]!.data.pixels, refreshes[1]!.data.pixels)).toBe(false);
    expect(hasNonBlackPixel(refreshes[0]!.data.pixels)).toBe(true);

    const state = await getState();
    expect(state.gears).toHaveLength(2);
    expect(events.some((event) => event.event === 'state.snapshot')).toBe(true);
    expect(events.some((event) => event.event === 'ledstrip.refreshed')).toBe(true);
    expect(snapshots.length).toBeGreaterThanOrEqual(1);
  } finally {
    controller.abort();
  }
});

test('emit still updates button state while animation is active', async () => {
  const ts = Date.now();
  const ack = await emitInputEvent({
    gearLabel: 'power-btn',
    event: 'press',
    ts,
    metadata: 'dGVzdA',
  });

  expect(ack.accepted).toBe(true);
  expect(ack.ts).toBe(ts);
  expect(ack.metadata).toBe('dGVzdA');

  const state = await getState();
  const button = state.gears.find((gear) => gear.kind === 'single_button');
  expect(button?.pressed).toBe(true);
});

function deferred<T>() {
  let settled = false;
  let resolveFn!: (value: T) => void;
  let rejectFn!: (reason?: unknown) => void;

  const promise = new Promise<T>((resolve, reject) => {
    resolveFn = (value) => {
      settled = true;
      resolve(value);
    };
    rejectFn = (reason) => {
      settled = true;
      reject(reason);
    };
  });

  return {
    get settled() {
      return settled;
    },
    promise,
    reject: rejectFn,
    resolve: resolveFn,
  };
}

async function withTimeout<T>(promise: Promise<T>, ms: number, message: string): Promise<T> {
  const timeout = new Promise<never>((_, reject) => {
    const id = setTimeout(() => {
      clearTimeout(id);
      reject(new Error(message));
    }, ms);
  });

  return Promise.race([promise, timeout]);
}

function hasNonBlackPixel(
  pixels: Array<{
    r: number;
    g: number;
    b: number;
  }>,
): boolean {
  return pixels.some((pixel) => pixel.r !== 0 || pixel.g !== 0 || pixel.b !== 0);
}

function samePixels(
  left: Array<{
    r: number;
    g: number;
    b: number;
  }>,
  right: Array<{
    r: number;
    g: number;
    b: number;
  }>,
): boolean {
  if (left.length !== right.length) return false;
  return left.every(
    (pixel, index) =>
      pixel.r === right[index]?.r && pixel.g === right[index]?.g && pixel.b === right[index]?.b,
  );
}
