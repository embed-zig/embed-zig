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
  event: 'press' | 'release';
  ts: number;
  metadata?: MetadataValue;
}): Promise<EmitAck> {
  const result = await client.get({
    path: {
      'gear-label': options.gearLabel,
      event: options.event,
    },
    query: {
      metadata: options.metadata,
      ts: options.ts,
    },
    url: '/emit/{gear-label}/{event}',
  });
  if (result.error) throw result.error;
  return result.data as EmitAck;
}
