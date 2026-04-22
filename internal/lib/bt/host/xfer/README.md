# xfer

`xfer` is the host-only byte-stream transfer layer used when one BLE ATT value
is too small for the payload.

It sits above ATT writes plus notify/indicate delivery and is only available
through the built-in HCI host stack. It is not part of the portable
`bt.Central` / `bt.Peripheral` surface.

## Why it exists

BLE GATT is a small attribute transport:

- client writes a characteristic value
- server serves reads or receives writes
- server pushes notifications or indications to subscribed clients

That is enough for small control points, but it becomes awkward when payloads
need chunking or retransmission.

`xfer` adds:

- chunked byte transfer above ATT
- ACK and loss-list based retry
- a symmetric host-side API for whole-payload reads and writes

## Package layout

```text
lib/bt/host/xfer/
  Chunk.zig
  read.zig
  write.zig
  send.zig
  recv.zig
```

- `Chunk.zig` defines the shared control markers, chunk headers, ACK, loss-list
  encoding, and MTU-derived sizing helpers.
- `read.zig` implements the client-side read loop.
- `write.zig` implements the client-side write loop.
- `send.zig` implements the server-side send loop for read-style transfers.
- `recv.zig` implements the server-side receive loop for write-style transfers.

Server-side characteristic helpers live next to `xfer` under `host/server/`:

- `Sender.zig` binds one characteristic to the read-side send loop.
- `Receiver.zig` binds one characteristic to the write-side receive loop.
- `host.Server.handleX(...)` bridges both directions onto one characteristic.

## Wire model

`xfer` uses one characteristic as a bidirectional transfer channel.

Read flow:

1. client subscribes to the characteristic
2. client writes `read_start_magic`
3. server read handler returns one byte payload
4. server streams chunks with notify or indicate
5. client ACKs when complete, or sends a loss-list for missing chunks

Write flow:

1. client subscribes to the characteristic
2. client writes `write_start_magic`
3. client streams chunked payload writes
4. server reassembles the payload
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

## Public API

Client side:

- `Characteristic.readX(allocator)` reads one chunked response body
- `Characteristic.writeX(data)` writes one chunked request body

Server side:

- `host.Server.handleX(service_uuid, char_uuid, handler, ctx)` registers one
  xfer characteristic with optional `.onRead` and `.onWrite` callbacks
- `Sender` is the direct read-side helper built on `xfer.send(...)`
- `Receiver` is the direct write-side helper built on `xfer.recv(...)`

`onRead` receives `(conn_handle, service_uuid, char_uuid)` and returns one
owned payload.

`onWrite` receives `(conn_handle, service_uuid, char_uuid, data)` after the
full payload has been reassembled.

## Constraints

- `xfer` requires notify or indicate delivery on the characteristic
- `readX` depends on a subscription-backed response stream
- `writeX` still enters through ATT writes; only the body is chunked
- one `(connection, characteristic)` supports at most one active xfer
  direction at a time
- payloads are whole-buffer transfers; streaming iterators are out of scope
- empty payloads are not supported in this protocol shape

## Future direction

- higher-level routing or RPC semantics should be built above the byte-stream
  `xfer` contract rather than encoded into the wire format
