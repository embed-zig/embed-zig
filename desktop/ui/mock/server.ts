import { join } from 'node:path';

type GearTopology =
  | {
      label: 'power-btn';
      kind: 'single_button';
    }
  | {
      label: 'strip';
      kind: 'ledstrip';
      pixel_count: number;
    };

type Color = {
  r: number;
  g: number;
  b: number;
};

type SingleButtonState = {
  label: 'power-btn';
  kind: 'single_button';
  pressed: boolean;
};

type LedStripState = {
  label: 'strip';
  kind: 'ledstrip';
  pixels: Color[];
  refresh_count: number;
};

type StateResponse = {
  ts_ms: number;
  gears: Array<SingleButtonState | LedStripState>;
};

type ServerEvent =
  | {
      event: 'state.snapshot';
      data: StateResponse;
    }
  | {
      event: 'ledstrip.refreshed';
      data: {
        label: 'strip';
        ts_ms: number;
        pixels: Color[];
        refresh_count: number;
      };
    };

const encoder = new TextEncoder();
const distDir = join(import.meta.dir, '..', 'dist');
export type MockServer = {
  port: number;
  stop(closeActiveConnections?: boolean): Promise<void>;
};

export function createMockServer(options?: {
  distPath?: string;
  port?: number;
  animationIntervalMs?: number;
}): MockServer {
  const topology: { gears: GearTopology[] } = {
    gears: [
      { label: 'power-btn', kind: 'single_button' },
      { label: 'strip', kind: 'ledstrip', pixel_count: 8 },
    ],
  };

  const state: {
    button: SingleButtonState;
    strip: LedStripState;
  } = {
    button: {
      label: 'power-btn',
      kind: 'single_button',
      pressed: false,
    },
    strip: {
      label: 'strip',
      kind: 'ledstrip',
      pixels: Array.from({ length: 8 }, () => black()),
      refresh_count: 0,
    },
  };

  const clients = new Set<ReadableStreamDefaultController<Uint8Array>>();
  const assetRoot = options?.distPath ?? distDir;
  const animationIntervalMs = options?.animationIntervalMs ?? 120;
  let animationPhaseDeg = 0;
  let animationTimer: ReturnType<typeof setInterval> | null = null;

  const json = (body: unknown, status = 200): Response =>
    new Response(JSON.stringify(body, null, 2), {
      status,
      headers: {
        'content-type': 'application/json; charset=utf-8',
        'cache-control': 'no-store',
      },
    });

  const snapshot = (ts = Date.now()): StateResponse => ({
    ts_ms: ts,
    gears: [
      { ...state.button },
      {
        ...state.strip,
        pixels: clonePixels(state.strip.pixels),
      },
    ],
  });

  const writeSse = (
    controller: ReadableStreamDefaultController<Uint8Array>,
    event: ServerEvent,
  ): void => {
    try {
      controller.enqueue(encoder.encode(`event: ${event.event}\n`));
      controller.enqueue(encoder.encode(`data: ${JSON.stringify(event.data)}\n\n`));
    } catch {
      clients.delete(controller);
    }
  };

  const broadcast = (event: ServerEvent): void => {
    for (const controller of clients) {
      writeSse(controller, event);
    }
  };

  const broadcastSnapshot = (ts = Date.now()): void => {
    broadcast({
      event: 'state.snapshot',
      data: snapshot(ts),
    });
  };

  const broadcastStripRefresh = (ts = Date.now()): void => {
    broadcast({
      event: 'ledstrip.refreshed',
      data: {
        label: 'strip',
        ts_ms: ts,
        pixels: clonePixels(state.strip.pixels),
        refresh_count: state.strip.refresh_count,
      },
    });
  };

  const animateStrip = (ts = Date.now()): void => {
    state.strip.pixels = Array.from({ length: state.strip.pixels.length }, (_, index) =>
      rainbow(animationPhaseDeg + index * (360 / state.strip.pixels.length)),
    );
    state.strip.refresh_count += 1;
    animationPhaseDeg = (animationPhaseDeg + 15) % 360;
  };

  const tickAnimation = (): void => {
    const ts = Date.now();
    animateStrip(ts);
    broadcastStripRefresh(ts);
    broadcastSnapshot(ts);
  };

  const ensureAnimation = (): void => {
    if (animationTimer) return;
    animationTimer = setInterval(tickAnimation, animationIntervalMs);
  };

  const stopAnimation = (): void => {
    if (!animationTimer) return;
    clearInterval(animationTimer);
    animationTimer = null;
  };

  const handleEmit = (url: URL): Response => {
    const parts = url.pathname.split('/').filter(Boolean);
    if (parts.length !== 3) {
      return json({ error: { code: 'INVALID_PATH', message: 'Expected /emit/{gear-label}/{event}.' } }, 400);
    }

    const [, gearLabel, eventName] = parts;
    const tsValue = url.searchParams.get('ts');
    const metadata = url.searchParams.get('metadata');

    if (!tsValue) {
      return json({ error: { code: 'MISSING_TS', message: 'Query parameter ts is required.' } }, 400);
    }

    const ts = Number(tsValue);
    if (!Number.isFinite(ts)) {
      return json({ error: { code: 'INVALID_TS', message: 'Query parameter ts must be a number.' } }, 400);
    }

    if (gearLabel !== 'power-btn') {
      return json({ error: { code: 'UNKNOWN_GEAR', message: `Unknown gear label: ${gearLabel}` } }, 404);
    }

    if (eventName !== 'press' && eventName !== 'release') {
      return json({ error: { code: 'INVALID_EVENT', message: `Unsupported event: ${eventName}` } }, 400);
    }

    state.button.pressed = eventName === 'press';
    broadcastSnapshot(ts);

    return json({
      accepted: true,
      gear_label: gearLabel,
      event: eventName,
      ts,
      metadata: metadata ?? undefined,
    });
  };

  const sse = (req: Request): Response => {
    const stream = new ReadableStream<Uint8Array>({
      start(controller) {
        clients.add(controller);
        ensureAnimation();
        writeSse(controller, {
          event: 'state.snapshot',
          data: snapshot(),
        });

        req.signal.addEventListener(
          'abort',
          () => {
            clients.delete(controller);
            if (clients.size === 0) {
              stopAnimation();
            }
            try {
              controller.close();
            } catch {}
          },
          { once: true },
        );
      },
      cancel() {
        // Bun will close the stream when the client disconnects.
      },
    });

    return new Response(stream, {
      headers: {
        'content-type': 'text/event-stream; charset=utf-8',
        'cache-control': 'no-store',
        connection: 'keep-alive',
      },
    });
  };

  const staticAsset = async (pathname: string): Promise<Response | null> => {
    const relativePath = pathname === '/' ? 'index.html' : pathname.slice(1);
    if (relativePath.includes('..')) {
      return json({ error: { code: 'INVALID_ASSET_PATH', message: 'Invalid asset path.' } }, 400);
    }

    const file = Bun.file(join(assetRoot, relativePath));
    if (!(await file.exists())) {
      return null;
    }

    return new Response(file, {
      headers: {
        'cache-control': 'no-store',
      },
    });
  };

  animateStrip();

  const server = Bun.serve({
    port: options?.port ?? 0,
    idleTimeout: 30,
    async fetch(req) {
      const url = new URL(req.url);

      if (req.method !== 'GET') {
        return json({ error: { code: 'METHOD_NOT_ALLOWED', message: 'Only GET is supported in mock server.' } }, 405);
      }

      if (url.pathname === '/topology') {
        return json(topology);
      }

      if (url.pathname === '/state') {
        return json(snapshot());
      }

      if (url.pathname === '/events') {
        return sse(req);
      }

      if (url.pathname.startsWith('/emit/')) {
        return handleEmit(url);
      }

      const asset = await staticAsset(url.pathname);
      if (asset) return asset;

      return json({ error: { code: 'NOT_FOUND', message: 'Unknown route.' } }, 404);
    },
  });
  const port = server.port;
  if (port === undefined) {
    throw new Error('Mock server did not expose a listening port.');
  }

  return {
    port,
    async stop(closeActiveConnections?: boolean) {
      stopAnimation();
      await server.stop(closeActiveConnections);
    },
  };
}

function black(): Color {
  return { r: 0, g: 0, b: 0 };
}

function red(): Color {
  return { r: 255, g: 64, b: 64 };
}

function rainbow(hueDeg: number): Color {
  const hue = ((hueDeg % 360) + 360) % 360;
  const sector = hue / 60;
  const chroma = 1;
  const x = chroma * (1 - Math.abs((sector % 2) - 1));

  let r1 = 0;
  let g1 = 0;
  let b1 = 0;

  if (sector < 1) {
    r1 = chroma;
    g1 = x;
  } else if (sector < 2) {
    r1 = x;
    g1 = chroma;
  } else if (sector < 3) {
    g1 = chroma;
    b1 = x;
  } else if (sector < 4) {
    g1 = x;
    b1 = chroma;
  } else if (sector < 5) {
    r1 = x;
    b1 = chroma;
  } else {
    r1 = chroma;
    b1 = x;
  }

  return {
    r: Math.round(r1 * 255),
    g: Math.round(g1 * 255),
    b: Math.round(b1 * 255),
  };
}

function clonePixels(pixels: Color[]): Color[] {
  return pixels.map((pixel) => ({ ...pixel }));
}

if (import.meta.main) {
  const server = createMockServer();
  console.log(`Mock desktop server running at http://127.0.0.1:${server.port}`);
}
