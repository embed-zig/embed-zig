# xfer

This directory is under active design and implementation work.

Do not treat this file as end-user documentation. Formal docs should be
written later, after the xfer restructuring is complete.

## Goal

Reshape host-side xfer into one dedicated package under `lib/bt/host/xfer/`
so the protocol and request/response model stop leaking across unrelated host
modules.

This package is host-only. It is layered on top of `host.Client`,
`host.Server`, and GATT notify/indicate behavior. It is not a portable
`bt.Central` / `bt.Peripheral` abstraction.

## Target layout

```text
lib/bt/host/xfer/
  AGENTS.md
  client.zig
  Chunk.zig
  Server.zig
  ServerMux.zig
```

## Responsibilities

### `client.zig`

Own the client-side xfer entrypoint.

Expected responsibilities:

- host the current `read_x` and `write_x` behavior
- provide the small client API used by host-side characteristics
- later add `get()` on top of the read-style xfer flow

`get()` should remain layered on the existing BLE model:

1. subscribe to the characteristic
2. send a control write to start the request
3. receive the response through notify/indicate chunks

### `Chunk.zig`

Own the shared xfer wire helpers used by both client and server.

Expected responsibilities:

- control marker definitions
- control packet detection
- chunk header encode/decode
- ack and loss-list helpers
- shared payload sizing helpers

This file replaces the current client-only `chunk.zig`. Server and client
must use the same chunk and control definitions.

### `Server.zig`

Own the server-side xfer engine as a file-as-struct type.

Expected responsibilities:

- recognize xfer control writes such as read start, write start, ack, and
  loss-list packets
- own per-connection, per-route xfer session state
- manage read-side response buffering and chunk transmission
- manage write-side chunk reassembly and completion
- clean up xfer session state on disconnect and subscription changes
- expose a narrow interface that `host.Server` can delegate to

`host.Server` should stay generic. `host/xfer/Server.zig` should own
xfer-specific protocol state and dispatch.

### `ServerMux.zig`

Own the request/response router above the raw xfer engine.

Expected responsibilities:

- register handlers for different xfer topics
- decode request metadata carried after the xfer start marker
- route requests to the correct handler
- present a request/response API with a shape similar in spirit to HTTP

`ServerMux` is not the chunk transport engine. It sits above `Server.zig`.

## Wire model

The base xfer model stays the same:

- `read_x` starts from a control write and returns data over notify/indicate
- `write_x` starts from a control write and continues with chunked request data

The protocol must allow request metadata after the control prefix.

Example future GET-like start packet:

```text
[read_start_magic][topic_id][request_id?]
```

Interpretation:

- `topic_id` identifies the logical endpoint or resource
- `request_id` identifies a specific in-flight request

Do not conflate those fields. Even if the first implementation only uses a
topic id, the layout should leave room for request correlation later.

## Topic model

`ServerMux` should route by a compact binary topic identifier rather than by a
text path string on the wire.

Current direction:

- `topic_id` can fit in 8 bytes
- `request_id` can fit in 4 bytes if needed
- a 12-byte request header after the magic is enough for the initial design

One characteristic should be able to host multiple logical topics.

## HTTP-like semantics

The intent is HTTP-like request/response semantics, not literal HTTP.

Mapping:

- characteristic: transport channel
- topic id: route or path-like selector
- `read_x`: GET-like request
- `write_x`: request-with-body style operation
- notify/indicate stream: response body transport

Important BLE constraint:

The request still enters through a GATT write. Large or structured replies
come back later through notify/indicate. There is no true HTTP-style "write a
request and receive a response body in the same response packet" primitive.

## Sync and async direction

Fast synchronous handlers are fine for the base protocol.

The package layout must not block future async behavior, such as:

- accept-now, reply-later flows
- correlating later notifications with `request_id`
- background work completing a response after the initial control write

## Migration direction

The expected migration path is:

1. move shared chunk helpers into `host/xfer/Chunk.zig`
2. move client-side read/write helpers into `host/xfer/client.zig`
3. introduce `host/xfer/Server.zig` as the server-side xfer engine
4. introduce `host/xfer/ServerMux.zig` as the topic router and
   request/response layer
5. update `host.Client` and `host.Server` to delegate to this package instead
   of embedding xfer details directly

## Editing guidance

While this work is in progress:

- prefer implementation notes and constraints here over polished prose
- avoid adding user-facing docs under `xfer/` until the structure settles
- keep protocol definitions shared between client and server
- keep `host.Server` generic and move xfer-specific state into `host/xfer`

## Working plan

This section is the in-progress implementation plan for the xfer
restructuring. It is intentionally execution-oriented and should evolve as the
work proceeds.

### Target architecture

The target split is:

- `host/xfer/client.zig`: the client entrypoint that owns the current
  `read_x` and `write_x` behavior and later grows `get()`
- `host/xfer/Chunk.zig`: the shared wire definition file for client and server
- `host/xfer/Server.zig`: the server-side xfer engine that owns protocol
  dispatch, per-connection xfer session state, and xfer-specific cleanup
- `host/xfer/ServerMux.zig`: the topic-based request/response layer above the
  raw engine

After this split:

- `host.Server` remains the generic host-side peripheral facade
- `host.Server` keeps peripheral binding, generic route registration, generic
  subscription acceptance, and low-level push capability
- xfer-specific routing, control packet handling, read/write transfer state,
  and xfer-only subscription bookkeeping move under `host/xfer`

### Phase 1: Extract shared wire helpers

Goal:

- create `host/xfer/Chunk.zig` as the shared home for chunk framing and
  control markers

Primary source:

- current `host/client/xfer/chunk.zig`

Planned work:

- move or copy the existing chunk header, bitmask, ack, loss-list, and size
  helpers into `host/xfer/Chunk.zig`
- update client-side xfer code to import the new shared file
- update server-side xfer code to import the same shared file instead of the
  client-only path
- preserve the current wire format exactly during this phase

Acceptance criteria:

- both client and server use one shared `Chunk.zig`
- no protocol behavior changes
- existing chunk-focused unit coverage still passes after the move

### Phase 2: Introduce `host/xfer/client.zig`

Goal:

- make xfer client behavior look like one package entrypoint rather than a
  collection of files under `host/client/xfer/`

Primary sources:

- current `host/client/xfer/read_x.zig`
- current `host/client/xfer/write_x.zig`

Planned work:

- create `host/xfer/client.zig`
- move or wrap the current `read_x` and `write_x` logic behind `read()` and
  `write()`
- update `host/client/Characteristic.zig` to delegate to the new package
- keep the current subscribe -> control write -> notify/indicate response flow
  unchanged

Acceptance criteria:

- `Characteristic.readX()` and `Characteristic.writeX()` still behave exactly
  as they do now
- client code stops depending on `host/client/xfer/chunk.zig`
- no GET-like API is required in this phase

### Phase 3: Extract the server xfer engine

Goal:

- move xfer-specific protocol machinery out of `host/Server.zig` into
  `host/xfer/Server.zig`

Primary source:

- current xfer handling in `host/Server.zig`

Planned work:

- move xfer route registration helpers and xfer route state into the new
  engine
- move read-side buffered response logic into the engine
- move write-side reassembly, ack, and loss-list handling into the engine
- move per-connection xfer session maps out of `host.Server`
- move xfer-specific cleanup on disconnect and subscription changes into the
  engine
- reduce `host.Server` to delegation points for xfer traffic

Important boundary:

- `host.Server` should still own generic subscription acceptance for plain
  server push use cases
- xfer internal subscription handling should stop leaking through the generic
  server code as much as possible

Acceptance criteria:

- `host/Server.zig` no longer owns `read_x_states` / `write_x_states`
- xfer dispatch is delegated to `host/xfer/Server.zig`
- existing `handleX()` behavior remains intact

### Phase 4: Clean up subscription ownership

Goal:

- reduce or remove xfer-specific leakage from `host/server/Subscription.zig`

Primary source:

- current `internal` subscription flag and xfer-aware cleanup behavior

Planned work:

- decide whether `Subscription` can become fully generic again
- if possible, remove the `internal` distinction from the generic server
  subscription type
- move any xfer-only subscription ownership tracking into the xfer engine

Acceptance criteria:

- generic server subscription behavior stays valid for non-xfer users
- xfer no longer depends on generic subscription internals more than necessary

### Phase 5: Introduce `host/xfer/ServerMux.zig`

Goal:

- add the logical request/response layer above the raw xfer transport

Planned work:

- create `host/xfer/ServerMux.zig`
- add registration by topic id
- parse request metadata carried after the xfer start marker
- present a request/response handler API shaped similarly to lightweight HTTP
  semantics
- keep retransmission, chunking, and loss recovery below the mux in the engine

Expected initial request model:

- `read_x` start packet can carry `[read_start_magic][topic_id][request_id?]`
- `topic_id` selects the logical endpoint
- `request_id` remains reserved for future correlation or async flows

Acceptance criteria:

- one characteristic can host multiple logical topics
- topic dispatch works without changing the underlying chunk transport model
- the mux layer does not duplicate chunk transport logic already owned by the
  engine

### Phase 6: Add client `get()` after the transport split settles

Goal:

- expose a higher-level GET-like helper on the client side only after the
  shared transport and server boundaries are stable

Planned work:

- add `get()` to `host/xfer/client.zig`
- encode the topic-bearing read-start request
- reuse the existing read-style subscription and chunk receive flow

Acceptance criteria:

- `get()` is layered on `read_x` semantics rather than inventing a second
  transport path
- topic encoding matches the server mux request parser

### Test plan

The restructuring should preserve and then rebalance the current coverage:

- keep chunk-focused unit tests with the shared `Chunk.zig`
- preserve the current client-side transfer behavior verified by existing
  `read_x` / `write_x` integration coverage
- preserve the current server-side `handleX()` integration coverage while the
  engine is extracted
- preserve connection cleanup behavior currently covered by the disconnect
  integration test
- add focused tests for mux topic parsing only after `ServerMux.zig` exists

When moving tests, prefer keeping them near the code that now owns the
behavior, but do not expand test scope during the early extraction phases.

### Deferred items

These are intentionally deferred until the transport split is complete:

- polished end-user docs or README updates
- async accept-now, reply-later response flows
- making `request_id` mandatory in the first wire format revision
- richer request metadata beyond fixed-size topic and request identifiers
- broader RPC features beyond the first topic-based GET-like design

### Execution order

Recommended order of implementation:

1. shared `Chunk.zig`
2. `host/xfer/client.zig`
3. `host/xfer/Server.zig`
4. generic subscription cleanup as needed
5. `host/xfer/ServerMux.zig`
6. client `get()`
7. final docs after the structure is stable
