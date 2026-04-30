import { client } from './generated/client.gen';
import type {
  LedStripRefreshedEvent,
  ServerEvent,
  StateResponse,
} from './generated/types.gen';

export type RuntimeEvent =
  | {
      event: 'state.snapshot';
      data: StateResponse;
    }
  | LedStripRefreshedEvent;

export function openEvents(onEvent: (event: RuntimeEvent) => void): AbortController {
  const controller = new AbortController();

  void (async () => {
    try {
      const result = await client.sse.get<ServerEvent>({
        signal: controller.signal,
        url: '/events',
        onSseEvent(event) {
          if (!event.event) return;
          if (event.event !== 'state.snapshot' && event.event !== 'ledstrip.refreshed') return;

          onEvent({
            data: event.data as RuntimeEvent['data'],
            event: event.event,
          } as RuntimeEvent);
        },
      });

      for await (const _ of result.stream) {
        // Drain the stream so the generated SSE client actually starts reading events.
      }
    } catch (error) {
      if (controller.signal.aborted) return;
      console.error('SSE error', error);
    }
  })();

  return controller;
}
