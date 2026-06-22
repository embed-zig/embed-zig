import { client } from './generated/client.gen';
import type {
  EmitAck,
  MetadataValue,
  StateResponse,
  TopologyResponse,
} from './generated/types.gen';

export async function getTopology(): Promise<TopologyResponse> {
  const result = await client.get({
    url: '/topology',
  });
  if (result.error) throw result.error;
  return result.data as TopologyResponse;
}

export async function getState(): Promise<StateResponse> {
  const result = await client.get({
    url: '/state',
  });
  if (result.error) throw result.error;
  return result.data as StateResponse;
}

export async function emitInputEvent(options: {
  gearLabel: string;
  event: 'press' | 'release' | 'down' | 'move' | 'up';
  ts: number;
  x?: number;
  y?: number;
  buttonId?: number;
  metadata?: MetadataValue;
}): Promise<EmitAck> {
  const result = await client.get({
    path: {
      'gear-label': options.gearLabel,
      event: options.event,
    },
    query: {
      metadata: options.metadata,
      button_id: options.buttonId,
      ts: options.ts,
      x: options.x,
      y: options.y,
    },
    url: '/emit/{gear-label}/{event}',
  });
  if (result.error) throw result.error;
  return result.data as EmitAck;
}
