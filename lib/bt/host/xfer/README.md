# xfer

`xfer` is the host-side transfer layer for BLE GATT operations that do not fit
in one ATT value or that benefit from lightweight request/response routing over
one characteristic.

It is intentionally host-only. The package sits on top of `bt.Host`,
`host.Client`, `host.Server`, ATT writes, and notify/indicate delivery. It is
not part of the portable `bt.Central` / `bt.Peripheral` abstraction.

## Why it exists

BLE GATT gives you a small attribute-oriented transport:

- client writes a characteristic value
- server reads or updates characteristic state
- server pushes notifications or indications to subscribed clients

That model is enough for simple control points, but it becomes awkward when:

- request or response bodies are larger than one ATT value
- one characteristic should carry multiple logical operations
- the caller wants a GET-like request/response flow instead of one raw write

`xfer` keeps the BLE transport model intact while adding:

- chunked payload transfer above ATT
- ACK and loss-list based recovery
- topic-based routing for GET-like reads
- a cleaner host-level API surface

## Package layout

```text
lib/bt/host/xfer/
  Chunk.zig
  client.zig
  Server.zig
  ServerMux.zig
```

- `Chunk.zig` defines shared wire helpers, control markers, chunk headers, ACK
  and loss-list encoding, and MTU-based sizing helpers.
- `client.zig` implements client-side `read`, `write`, and `get`.
- `Server.zig` owns server-side xfer session state, chunk transmission, and
  write-side reassembly.
- `ServerMux.zig` routes one xfer characteristic to many logical topic
  handlers.

## Wire model

`xfer` uses one characteristic as a bidirectional transfer channel.

Read-style flow:

1. client subscribes to the characteristic
2. client writes a `read_start_magic` control packet
3. server runs the read handler and buffers the response body
4. server streams response chunks with notify or indicate
5. client ACKs when complete, or sends a loss-list when chunks are missing

Write-style flow:

1. client subscribes to the characteristic
2. client writes a `write_start_magic` control packet
3. client sends chunked request body writes
4. server reassembles the body
5. server replies with ACK or one or more loss-list packets

The shared chunk header carries:

- `total`: total chunk count
- `seq`: 1-based chunk sequence

Large loss-lists may be split across multiple packets.

## ATT MTU

Chunk sizing is derived from the negotiated ATT MTU of the connection.

That MTU affects:

- maximum chunk payload size
- total chunk count
- retransmit and loss-list packet sizing
- maximum notification or indication payload size

Client and server must use the same effective MTU for the same connection.

## GET-like reads

`get()` is a small wrapper over read-style xfer.

It sends:

```text
[read_start_magic][topic_id][metadata...]
```

Current routing uses a binary `topic_id` (`u64`). Any remaining bytes after
that fixed-width topic are request metadata.

`get()` emits `topic_id` plus caller-provided metadata.

This is HTTP-like in intent, not literal HTTP:

- characteristic: transport channel
- topic: route selector
- `get()`: GET-like request
- notify/indicate chunk stream: response body

There is no attempt to map HTTP headers, methods, or status codes directly
onto BLE.

## Public API

Client side:

- `Characteristic.readX(allocator)` reads a chunked response body
- `Characteristic.writeX(data)` writes a chunked request body
- `Characteristic.get(topic, metadata, allocator)` performs a topic-routed
  GET-like read

Server side:

- `host.Server.handleX(service_uuid, char_uuid, handler, ctx)` registers raw
  xfer read/write handlers for one characteristic
- `ServerMux.handle(topic, handler, ctx)` registers logical routes above a
  single xfer characteristic
- `ServerMux.xHandler()` adapts the mux back into `handleX(... .read = ...)`

`ReadXRequest` exposes `topic` and trailing `metadata` as separate fields.
`ServerMux.Request` keeps the same split, but with a required `topic` because
mux routing only applies to topic-addressed requests.

## Constraints

- `xfer` requires notify or indicate delivery on the characteristic
- `readX` and `get()` depend on a subscription-backed response stream
- `writeX` still enters through ATT writes; only the body is chunked
- one `(connection, characteristic)` supports at most one active read transfer at
  a time; an identical re-request is treated as a replay, but a different
  request must wait for the current read to finish
- one connection may have independent xfer state per routed characteristic
- the xfer engine owns xfer session cleanup; `host.Server` stays generic

## Future direction

- async accept-now, reply-later patterns should build on the existing topic and
  metadata model rather than replacing the chunk transport
