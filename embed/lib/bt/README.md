# lib/bt — Bluetooth for embed-zig

Portable Bluetooth package built on top of `stdz`. Provides a unified
BLE API that works across different backends — from bare-metal HCI host
stacks to OS-level APIs like Apple CoreBluetooth and Android BLE.

Application code programs against two VTable interfaces (`Central` and
`Peripheral`). The backend is injected at init time, so the same
application logic (e.g. a BLE command protocol, sensor data collection,
OTA firmware update) is reusable across all platforms without changes.

Currently implements BLE (Low Energy) only. Classic Bluetooth (BR/EDR)
is planned as a future addition under the same package.

## Table of Contents

- [Design principles](#design-principles)
- [Dependency](#dependency)
- [Architecture](#architecture)
- [Package structure](#package-structure)
- [Layer diagram](#layer-diagram)
- [bt/Central](#btcentral)
- [bt/Peripheral](#btperipheral)
- [bt/Transport](#bttransport)
- [bt/host (HCI backend)](#bthost-hci-backend)
  - [Design direction](#design-direction)
  - [Hci](#hci)
  - [Host facade](#host-facade)
  - [Client and Server](#client-and-server)
  - [Transfer extensions](#transfer-extensions)
  - [hci (codec)](#hci-codec)
  - [l2cap](#l2cap)
  - [att](#att)
  - [gap](#gap)
  - [smp](#smp)
  - [gatt](#gatt)
- [Platform backends](#platform-backends)
- [Usage examples](#usage-examples)

## Design principles

1. **Two VTable interfaces for application code.** `Central` and
   `Peripheral` are type-erased VTable structs (same pattern as
   `net.Conn`). Application code programs against these interfaces
   only. The backing implementation — HCI host stack, CoreBluetooth,
   Android BLE — is invisible to the application.

2. **Comptime `std` injection.** Modules that need platform primitives
   take `comptime std: type` (the sealed stdz namespace) for
   `std.Thread`, `std.mem`, etc. and the runtime `time` namespace. No global state.

3. **VTable transport for HCI.** The built-in HCI host stack uses a
   `Transport` VTable for the physical bus. Platform provides the
   concrete implementation (H4, H5, USB, SDIO).

4. **Zero-allocation parsing.** HCI commands/events, ACL packets,
   L2CAP headers, ATT PDUs — parsers return slices into the input
   buffer or fixed-size structs. No heap allocation in the data path.

5. **Comptime GATT tables.** Service and characteristic definitions
   are comptime arrays. Handle assignments, attribute counts, and
   UUID lookups are resolved at build time.

6. **Allocator-explicit.** Types that need heap take an `Allocator`
   parameter. No hidden allocations.

7. **Spec-traceable.** Types and constants reference Bluetooth Core
   Spec volume/part/section numbers in doc comments.

## Dependency

```zig
const stdz = @import("stdz").make(platform);
const glib = @import("glib");
const bt = @import("bt");
```

`lib/bt` depends on the sealed `stdz` namespace for:
- `lib.Thread` — Mutex, background host task
- `grt.time` — monotonic deadlines, timeouts, connection supervision
- `lib.mem` — Allocator
- `lib.atomic` — lock-free HCI flow control counters

## Architecture

The package has two layers:

**Application layer** — `Central` and `Peripheral` VTable interfaces.
Application code (BLE command protocols, sensor apps, OTA, etc.)
programs against these and is fully portable. This layer has zero
dependency on HCI, L2CAP, ATT, or any protocol internals.

**Backend layer** — concrete implementations of Central/Peripheral.
Three categories:

| Backend          | Central impl                  | Peripheral impl                   | Needs Transport? |
|------------------|-------------------------------|-----------------------------------|------------------|
| HCI host stack   | `host.Central` via `bt.Host`  | `host.Peripheral` via `bt.Host`   | Yes              |
| CoreBluetooth    | platform provides   | platform provides      | No               |
| Android BLE      | platform provides   | platform provides      | No               |

The HCI host stack (`bt/host/`) is built into `lib/bt` and implements
Central/Peripheral by driving the full protocol stack
(HCI → L2CAP → ATT → GAP → GATT) over a `Transport` VTable.

On top of the raw role adapters, the host backend is evolving an
**extension layer** for higher-level data transfer and RPC-style APIs.
This layer is intentionally host-specific: it builds on `bt.Host`,
`host.Client`, and `host.Server`, not on the portable `bt.Central` /
`bt.Peripheral` VTables.

CoreBluetooth and Android backends are provided by the platform.
They implement the Central/Peripheral VTable directly, bridging to
the OS API. No HCI, Transport, or protocol internals involved — the
OS handles everything below GATT.

## Package structure

```
lib/bt.zig                    Root; make(lib) entry point
lib/bt/
  ── Application layer (backend-agnostic) ──
  Central.zig                 Type-erased Central interface (VTable)
  Peripheral.zig              Type-erased Peripheral interface (VTable)
  Transport.zig               Type-erased HCI transport (VTable)
  Hci.zig                     Type-erased controller-facing HCI interface
  Host.zig                    Host bundle exposing central/peripheral plus host-level views
  Mocker.zig                  Multi-node Bluetooth test world
  mocker/
    Hci.zig                   Mock controller implementing bt.Hci

  ── HCI backend (only needed when driving raw HCI) ──
  host/
    Hci.zig                   HCI host: holds Transport, event loop
    Central.zig               Central role adapter backed by bt.Hci
    Peripheral.zig            Peripheral role adapter backed by bt.Hci
    Client.zig                Host-level client facade built on Central
    Server.zig                Host-level server facade built on Peripheral
    hci/
      commands.zig            HCI command encoder (Vol 4 Part E)
      events.zig              HCI event decoder
      acl.zig                 ACL data packet codec (Vol 4 Part E 5.4.2)
      status.zig              HCI status/error codes (Vol 2 Part D)
    l2cap.zig                 LE L2CAP: header parse, reassembly, fragmentation
    att.zig                   ATT PDU codec, UUID, opcodes (Vol 3 Part F)
    Gap.zig                   LE GAP state machine: adv, scan, connect
    client/
      Characteristic.zig      Host-level characteristic helpers including readX/writeX
    server/
      Sender.zig              Chunked read responder bound to one characteristic
      Receiver.zig            Chunked write receiver bound to one characteristic
    xfer/
      // host.Server / host.Client protocol helpers
      Chunk.zig               Shared xfer wire helpers
      read.zig                Client read-side transfer loop
      write.zig               Client write-side transfer loop
      send.zig                Server send-side transfer loop
      recv.zig                Server receive-side transfer loop
    gatt/
      server.zig              GATT server: comptime service table, PDU dispatch
      client.zig              GATT client: discovery, read, write, subscribe
```

## Layer diagram

```
┌──────────────────────────────────────────────────────────────┐
│                      Application code                        │
│  (BLE command protocol, sensor app, OTA, ...)                │
│  Only depends on Central / Peripheral VTable.                │
├──────────────┬───────────────────────────────────────────────┤
│  bt.Central  │              bt.Peripheral                    │
│  (VTable)    │              (VTable)                         │
├══════════════╧═══════════════════════════════════════════════╡
│  Backend implementations (one per platform)                  │
├──────┬───────────────┬───────────────────────────────────────┤
│      │               │                                       │
│  host.Central   host.Peripheral  CoreBluetooth / Android /.. │
│      │               │            (platform provides,        │
│      └───────┬───────┘             no host/ needed)          │
│              │                                               │
│        host.Client    host.Server                            │
│              │             │                                 │
│              └───────┬─────┘                                 │
│                      │                                       │
│                     host/xfer                                │
│                      │                                       │
│          bt/host/Hci ─────────────────────────────┐          │
│              │                                    │          │
│    ┌─────────┴──────────┐                         │          │
│    │  gatt              │  All of host/ is        │          │
│    ├────────────────────┤  internal to the        │          │
│    │  att               │  HCI backend.           │          │
│    ├────────────────────┤  CoreBluetooth /         │          │
│    │  l2cap             │  Android skip this      │          │
│    ├────────────────────┤  entirely.              │          │
│    │  hci (codec)       │                         │          │
│    ├────────────────────┤                         │          │
│    │  gap / smp         │                         │          │
│    └─────────┬──────────┘                         │          │
│              │                                    │          │
│       bt.Transport (VTable)                       │          │
│       Platform provides: H4, H5, USB, SDIO, ...  │          │
│              │                                    │          │
├──────────────┴────────────────────────────────────┘──────────┤
│                    lib (stdz.make)                           │
│              Thread / mem / atomic + monotonic time              │
└──────────────────────────────────────────────────────────────┘
```

## bt/Central

Type-erased BLE Central interface. Application code programs against
this regardless of backend.

```zig
const Central = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    start: *const fn (ptr: *anyopaque) StartError!void,
    stop: *const fn (ptr: *anyopaque) void,
    startScanning: *const fn (ptr: *anyopaque, config: ScanConfig) ScanError!void,
    stopScanning: *const fn (ptr: *anyopaque) void,
    connect: *const fn (ptr: *anyopaque, addr: BdAddr, addr_type: AddrType, params: ConnParams) ConnectError!void,
    disconnect: *const fn (ptr: *anyopaque, conn_handle: u16) void,
    discoverServices: *const fn (ptr: *anyopaque, conn_handle: u16, out: []DiscoveredService) GattError!usize,
    discoverChars: *const fn (ptr: *anyopaque, conn_handle: u16, start_handle: u16, end: u16, out: []DiscoveredChar) GattError!usize,
    gattRead: *const fn (ptr: *anyopaque, conn_handle: u16, attr_handle: u16, out: []u8) GattError!usize,
    gattWrite: *const fn (ptr: *anyopaque, conn_handle: u16, attr_handle: u16, data: []const u8) GattError!void,
    subscribe: *const fn (ptr: *anyopaque, conn_handle: u16, cccd_handle: u16) GattError!void,
    unsubscribe: *const fn (ptr: *anyopaque, conn_handle: u16, cccd_handle: u16) GattError!void,
    getState: *const fn (ptr: *anyopaque) State,
    addEventHook: *const fn (ptr: *anyopaque, ctx: ?*anyopaque, cb: *const fn (?*anyopaque, CentralEvent) void) void,
    getAddr: *const fn (ptr: *anyopaque) ?BdAddr,
    deinit: *const fn (ptr: *anyopaque) void,
};
```

Convenience methods delegate to the vtable:

```zig
pub fn start(self: Central) StartError!void {
    return self.vtable.start(self.ptr);
}
// ... same for all other methods
```

Any concrete type with matching methods wraps into a Central via
`Central.make(&my_hci_central)` or `Central.make(&my_corebluetooth)`.

Events: `device_found`, `connected`, `disconnected`, `notification`.

## bt/Peripheral

Type-erased BLE Peripheral interface. Same VTable pattern as Central.

Design follows a small request-router pattern:

| HTTP                | BLE Peripheral                       |
|---------------------|--------------------------------------|
| ListenAndServe      | startAdvertising                     |
| HandleFunc(path,fn) | handle(svc_uuid, char_uuid, fn, ctx) |
| http.Request        | Request (op, conn, data)             |
| http.ResponseWriter | ResponseWriter (write, ok, err)      |
| Shutdown            | stopAdvertising                      |
| Server Push / SSE   | notify / indicate                    |

```zig
const Peripheral = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    start: *const fn (ptr: *anyopaque) StartError!void,
    stop: *const fn (ptr: *anyopaque) void,
    startAdvertising: *const fn (ptr: *anyopaque, config: AdvConfig) AdvError!void,
    stopAdvertising: *const fn (ptr: *anyopaque) void,
    handle: *const fn (ptr: *anyopaque, svc_uuid: u16, char_uuid: u16, HandlerFn, ctx: ?*anyopaque) void,
    notify: *const fn (ptr: *anyopaque, conn_handle: u16, char_uuid: u16, data: []const u8) GattError!void,
    indicate: *const fn (ptr: *anyopaque, conn_handle: u16, char_uuid: u16, data: []const u8) GattError!void,
    disconnect: *const fn (ptr: *anyopaque, conn_handle: u16) void,
    getState: *const fn (ptr: *anyopaque) State,
    addEventHook: *const fn (ptr: *anyopaque, ctx: ?*anyopaque, cb: *const fn (?*anyopaque, PeripheralEvent) void) void,
    getAddr: *const fn (ptr: *anyopaque) ?BdAddr,
    deinit: *const fn (ptr: *anyopaque) void,
};
```

Events: `connected`, `disconnected`, `advertising_started`,
`advertising_stopped`, `mtu_changed`.

## bt/Transport

Type-erased HCI transport interface (same VTable pattern as `net.Conn`).
Only used by the HCI backend (`bt/host/`). CoreBluetooth/Android
backends do not need a Transport — the OS handles everything below GATT.

Concrete transport implementations (H4, H5, USB, ...) are provided by
the platform, not by `lib/bt`.

```zig
const Transport = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    send: *const fn (ptr: *anyopaque, buf: []const u8) SendError!void,
    recv: *const fn (ptr: *anyopaque, buf: []u8) RecvError!usize,
    reset: *const fn (ptr: *anyopaque) void,
    deinit: *const fn (ptr: *anyopaque) void,
    setRecvTimeout: *const fn (ptr: *anyopaque, ms: ?u32) void,
    setSendTimeout: *const fn (ptr: *anyopaque, ms: ?u32) void,
};

pub const SendError = error{ Timeout, HwError, Unexpected };
pub const RecvError = error{ Timeout, HwError, Unexpected };
```

## bt/host (HCI backend)

The built-in HCI host stack. Implements `Central` and `Peripheral`
by driving the full BLE protocol stack over a `Transport`.

Most of `host/` is specific to the raw-HCI backend. If the platform uses
CoreBluetooth or Android BLE, `host/` is not compiled at all.

### Design direction

The direction for the HCI backend is to expose two layers:

1. A **portable role layer**: `bt.Central` and `bt.Peripheral`.
2. A **host-only extension layer**: `bt.Host`, `host.Client`,
   `host.Server`, and transfer-oriented helpers under `host/xfer/`.

This keeps the public portable surface small while still allowing richer
host-side protocols to be built once and reused across raw-HCI targets.

### Hci

The built-in host stack is exposed as `bt.HciHost`. It owns the concrete
HCI coordinator, runs the event loop, and binds one shared controller
instance to both Central and Peripheral adapters:

```zig
const Host = bt.HciHost(stdz, platform.Channel);
var host = try Host.init(allocator, transport, .{
    .spawn_config = .{ .name = "bt-hci-rx" },
});
defer host.deinit();

var central = host.central();
var peripheral = host.peripheral();
```

### Host facade

`bt.HciHost` is the join point for one shared controller-facing stack.
Today it exposes the portable role views:

```zig
var central = host.central();
var peripheral = host.peripheral();
```

`bt.Host` also exposes host-only facades:

```zig
var client = host.client();
var server = host.server();
```

These are not portable cross-platform BLE interfaces. They are extensions
for the built-in HCI host backend, layered above `host.Central` and
`host.Peripheral`.

### Client and Server

`host.Client` is the higher-level wrapper around the Central role.
It is the place for client-side convenience APIs that are more structured
than raw GATT primitives.

`host.Server` is the higher-level wrapper around the Peripheral role.
It is the place for request routing, service registration, and server-side
convenience behavior on top of the raw Peripheral contract.

Current layout:

```text
host/Client.zig
host/client/

host/Server.zig
host/server/
```

The layering is:

```text
bt.Host
  -> host.Central -> host.Client
  -> host.Peripheral -> host.Server
```

### Transfer extensions

The existing transfer-oriented helpers such as `readX` and `writeX` live
under the host-only `host/xfer/` package instead of as a
top-level `bt/xfer` package.

Reasoning:

- They are not backend-agnostic transport primitives.
- They build on host client/server connection semantics and GATT conventions.
- Future higher-level RPC or routing helpers should build above the existing
  xfer engine rather than inside generic client or server wrappers.

The layout is:

```text
host/xfer/
  Chunk.zig
  read.zig
  write.zig
  send.zig
  recv.zig

host/server/
  Sender.zig
  Receiver.zig
```

In other words, `xfer` becomes a **host-only transfer extension layer**,
not a separate top-level Bluetooth abstraction.

`host/client/Characteristic.zig` exposes the client convenience methods
`readX` and `writeX`. On the server side, `host.Server.handleX(...)` bridges
`host/server/Sender.zig` and `host/server/Receiver.zig` onto one xfer
characteristic, while `host/xfer/send.zig` and `host/xfer/recv.zig` carry the
shared protocol loops.

Internally, `Hci` orchestrates:
1. Send HCI commands via `Transport.send`
2. Receive HCI events via `Transport.recv` (blocking, dedicated thread)
3. Decode events → feed to GAP state machine
4. Reassemble ACL → L2CAP → route by CID to ATT or SMP
5. ATT PDUs → GATT server/client dispatch

### hci (codec)

Pure stateless codec functions. No I/O, no Transport dependency.

**commands** — HCI command encoder. Writes into a caller-provided
buffer, returns a slice:

```zig
var buf: [hci.commands.MAX_CMD_LEN]u8 = undefined;
const pkt = hci.commands.reset(&buf);
// pkt = [0x01, 0x03, 0x0C, 0x00]

const pkt2 = hci.commands.leSetAdvEnable(&buf, true);
// opcode 0x200A, 1 byte param
```

Generic encoder for any opcode:

```zig
const pkt = hci.commands.encode(&buf, hci.commands.READ_BD_ADDR, &.{});
```

**events** — HCI event decoder. Returns a tagged union:

```zig
const evt = hci.events.decode(raw_bytes) orelse return;
switch (evt) {
    .command_complete => |cc| { ... },
    .command_status => |cs| { ... },
    .le_connection_complete => |lc| { ... },
    .disconnection_complete => |dc| { ... },
    .num_completed_packets => |ncp| { ... },
    .unknown => { ... },
}
```

**acl** — ACL data packet codec (Vol 4 Part E 5.4.2):

```zig
var buf: [hci.acl.MAX_PACKET_LEN]u8 = undefined;
const pkt = hci.acl.encode(&buf, conn_handle, .first_auto_flush, payload);

const hdr = hci.acl.parseHeader(raw[1..]) orelse return;
// hdr.conn_handle, hdr.pb_flag, hdr.bc_flag, hdr.data_len
```

Constants: `LE_DEFAULT_DATA_LEN` (27), `LE_MAX_DATA_LEN` (251).

**status** — HCI status codes (Vol 2 Part D):

```zig
hci.Status.success            // 0x00
hci.Status.unknown_command    // 0x01
hci.Status.connection_timeout // 0x08
hci.Status.remote_terminated  // 0x13
status.isSuccess()            // convenience check
```

### l2cap

LE L2CAP (Vol 3 Part A). BLE uses three fixed channels:

| CID    | Channel            |
|--------|--------------------|
| 0x0004 | ATT                |
| 0x0005 | LE Signaling       |
| 0x0006 | SMP                |

Header format: `[length: u16][CID: u16]` (4 bytes).

**Reassembler** — reassembles ACL fragments into complete L2CAP SDUs:

```zig
var reasm = l2cap.Reassembler{};
if (reasm.feed(acl_header, acl_payload)) |sdu| {
    // sdu.conn_handle, sdu.cid, sdu.data
}
```

**Fragment iterator** — splits an L2CAP SDU into ACL-sized fragments:

```zig
var iter = l2cap.fragmentIterator(&buf, att_payload, l2cap.CID_ATT, conn_handle, max_data_len);
while (iter.next()) |fragment| {
    try transport.send(fragment);
}
```

### att

Attribute Protocol (Vol 3 Part F).

Constants:
- `DEFAULT_MTU` = 23 (Vol 3 Part F 3.2.8)
- `MAX_MTU` = 517 (Vol 3 Part F 3.2.9)
- `MAX_PDU_LEN` = MAX_MTU

**UUID** — 16-bit and 128-bit Bluetooth UUIDs:

```zig
const uuid = att.UUID.from16(0x2800);   // Primary Service
uuid.byteLen()                          // 2
uuid.eql(other)                         // equality check
uuid.writeTo(&buf)                      // serialize
att.UUID.readFrom(&buf, len)            // deserialize
```

**PDU encode/decode:**

```zig
// Encode
att.encodeErrorResponse(&buf, .read_request, handle, .attribute_not_found);
att.encodeReadResponse(&buf, value_bytes);
att.encodeWriteResponse(&buf);
att.encodeMtuResponse(&buf, 512);
att.encodeNotification(&buf, handle, data);
att.encodeIndication(&buf, handle, data);

// Decode
const pdu = att.decodePdu(raw) orelse return;
switch (pdu) {
    .exchange_mtu_request => |req| { req.client_mtu },
    .read_request => |rr| { rr.handle },
    .write_request => |wr| { wr.handle, wr.value },
    ...
}
```

### gap

LE GAP state machine (Vol 3 Part C). Manages advertising, scanning,
and connection establishment by generating HCI command sequences.

States: `idle`, `scanning`, `advertising`, `connecting`, `connected`.

```zig
var gap = Gap.init();

try gap.startAdvertising(.{
    .adv_data = &[_]u8{ 0x02, 0x01, 0x06, 0x04, 0x09, 'Z', 'i', 'g' },
});

try gap.startScanning(.{});

try gap.connect(peer_addr, .public, .{});

while (gap.nextCommand()) |cmd| {
    try transport.send(cmd.data[0..cmd.len]);
}

gap.handleEvent(hci_event);
```

### smp

Security Manager Protocol (Vol 3 Part H). Handles LE pairing,
key generation, and encryption setup. Planned.

### gatt

**Server** — comptime GATT service table. Handle assignments and
attribute counts resolved at build time:

```zig
const MyServer = gatt.GattServer(lib, &.{
    gatt.Service(0x180D, &.{
        gatt.Char(0x2A37, .{ .read = true, .notify = true }),
        gatt.Char(0x2A38, .{ .read = true }),
    }),
    gatt.Service(0xFFE0, &.{
        gatt.Char(0xFFE1, .{ .write = true, .notify = true }),
    }),
});
```

Handler registration follows the `http.HandleFunc` pattern:

```zig
var server = MyServer.init();

server.handle(0x180D, 0x2A37, struct {
    pub fn serve(req: *gatt.Request, w: *gatt.ResponseWriter) void {
        if (req.op == .read) {
            w.write(&[_]u8{ 0x00, 72 });
        }
    }
}.serve, null);
```

**Client** — GATT client for the Central role. Service/characteristic
discovery, read, write, and notification subscription.

## Platform backends

Each platform provides a concrete implementation of `Central` and/or
`Peripheral` that wraps into the VTable interface.

**Bare-metal (HCI)** — use the built-in host stack:

```zig
const Host = bt.HciHost(stdz, platform.Channel);

var h4 = platform.H4Uart.init(&uart);
var transport = bt.Transport.init(&h4);
var host = try Host.init(allocator, transport, .{});

var central = host.central();
var peripheral = host.peripheral();

var client = host.client();
var server = host.server();
```

**Apple (CoreBluetooth)** — platform bridges CBCentralManager:

```zig
var cb_central = platform.CoreBluetoothCentral.init();
var central = bt.Central.make(&cb_central);
```

**Android** — platform bridges android.bluetooth.le:

```zig
var android_central = platform.AndroidBleCentral.init(context);
var central = bt.Central.make(&android_central);
```

Application code is identical in all three cases:

```zig
try central.startScanning(.{ .active = true });
// works on ESP32, iPhone, and Android
```

## Usage examples

### Portable BLE scanner

```zig
const stdz = @import("stdz").make(platform);
const bt = @import("bt");

fn runScanner(central: bt.Central) !void {
    central.addEventHook(null, struct {
        fn onEvent(_: ?*anyopaque, evt: bt.CentralEvent) void {
            switch (evt) {
                .device_found => |report| {
                    log.info("found: {s} rssi={}", .{ report.getName(), report.rssi });
                },
                else => {},
            }
        }
    }.onEvent);

    try central.startScanning(.{ .active = true, .timeout = 5 * glib.time.duration.Second });
}
```

### GATT peripheral (Heart Rate)

```zig
const stdz = @import("stdz").make(platform);
const bt = @import("bt");

fn runHeartRate(peripheral: bt.Peripheral) !void {
    peripheral.handle(0x180D, 0x2A37, struct {
        pub fn serve(req: *bt.Peripheral.Request, w: *bt.Peripheral.ResponseWriter) void {
            if (req.op == .read) {
                w.write(&[_]u8{ 0x00, 72 });
            }
        }
    }.serve, null);

    try peripheral.startAdvertising(.{
        .device_name = "Zig-HR",
        .service_uuids = &.{0x180D},
    });
}
```

### BLE command protocol (reusable across platforms)

```zig
pub fn CommandClient(comptime bt: type) type {
    return struct {
        central: bt.Central,
        conn_handle: ?u16 = null,

        const Self = @This();

        pub fn connect(self: *Self, addr: bt.Central.BdAddr) !void {
            const info = try self.central.connect(addr, .public, .{});
            self.conn_handle = info.conn_handle;
        }

        pub fn sendCommand(self: *Self, cmd: []const u8) !void {
            const handle = self.conn_handle orelse return error.NotConnected;
            try self.central.gattWrite(handle, CMD_CHAR_HANDLE, cmd);
        }

        pub fn readResponse(self: *Self, buf: []u8) !usize {
            const handle = self.conn_handle orelse return error.NotConnected;
            return self.central.gattRead(handle, RESP_CHAR_HANDLE, buf);
        }
    };
}
```
