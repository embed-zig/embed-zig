# lib/net/netip — Go `net/netip` for embed-zig

`netip` is the planned pure value-type IP package for `lib/net`.

Its primary design target is Go's
[`net/netip`](https://pkg.go.dev/net/netip), not `std.net`.
This package should be designed as the value-address foundation for
embed-zig's networking stack, with API names, behavior, and edge cases kept as
close to Go as Zig reasonably allows.

The existing `stdz.net.Address` family is socket-oriented:

- it mirrors OS socket address layout
- it carries a port
- it is the right type for dialing, binding, and DNS answers

`netip` is meant to solve a different problem:

- pure address math and parsing
- comparable value types
- prefix operations
- zero-allocation string parsing and formatting
- no dependency on socket layout

In short:

- use `stdz.net.Address` at the OS / socket boundary
- use `netip` in logic, config, routing, filtering, CIDR, and map keys

## Goals

1. Replicate Go `net/netip` as closely as practical:
   `Addr`, `AddrPort`, `Prefix`, parsing, formatting, ordering, and
   classification semantics.
2. Stay allocator-free for normal construction, parsing, comparison, and
   formatting into caller-provided buffers.
3. Keep the package independent from `comptime std injection`.
   Like `net/url`, this should be a pure utility package.
4. Interoperate cleanly with existing `stdz.net.Address`,
   `stdz.net.Ip4Address`, and `stdz.net.Ip6Address` at the boundary.
5. Be usable in `comptime` where practical.

## Non-goals

At least for the first phase, `netip` is not trying to be:

- a socket API
- a DNS resolver
- a route table implementation
- a stringly typed zone-name package
- a wrapper around `std.net`

## Why not reuse `stdz.net.Address`?

`stdz.net.Address` is the right boundary type for networking syscalls, but it
has several properties that make it awkward for general-purpose IP logic:

- port is always part of the representation
- layout is tied to `posix.sockaddr`
- IPv4 and IPv6 are represented as OS-facing structs, not normalized value
  types
- it is less natural for CIDR, prefix masking, comparisons, and map/set keys

Go solved the same split by keeping both:

- `net.Addr` / `net.TCPAddr` / `net.UDPAddr` for sockets and protocol edges
- `net/netip` for pure IP values

This package follows the same separation.

## Proposed package shape

```text
lib/net/
  netip.zig              root re-export module
  netip/
    README.md
    Addr.zig
    AddrPort.zig
    Prefix.zig
```

The root module should look like:

```zig
pub const Addr = @import("netip/Addr.zig");
pub const AddrPort = @import("netip/AddrPort.zig");
pub const Prefix = @import("netip/Prefix.zig");
```

File layout rule:

- use file-as-type modules
- `Addr.zig` is the `Addr` type module
- `AddrPort.zig` is the `AddrPort` type module
- `Prefix.zig` is the `Prefix` type module
- avoid nested naming like `Addr.Addr` or `Prefix.Prefix`

A target file should therefore look like:

```zig
const Addr = @This();

// fields
// methods
```

## Core types

### Addr

Represents a single IP address without a port.

Target API shape:

```zig
const Addr = @This();

// fields and methods:

pub fn parse(s: []const u8) !Addr;
pub fn mustParse(comptime s: []const u8) Addr;

pub fn from4(v: [4]u8) Addr;
pub fn from16(v: [16]u8) Addr;

pub fn isValid(self: Addr) bool;
pub fn is4(self: Addr) bool;
pub fn is6(self: Addr) bool;
pub fn is4In6(self: Addr) bool;

pub fn as4(self: Addr) ?[4]u8;
pub fn as16(self: Addr) ?[16]u8;
pub fn unmap(self: Addr) Addr;

pub fn bitLen(self: Addr) u8;
pub fn compare(a: Addr, b: Addr) std.math.Order;
pub fn less(a: Addr, b: Addr) bool;

pub fn isLoopback(self: Addr) bool;
pub fn isPrivate(self: Addr) bool;
pub fn isMulticast(self: Addr) bool;
pub fn isLinkLocalUnicast(self: Addr) bool;
pub fn isLinkLocalMulticast(self: Addr) bool;
pub fn isGlobalUnicast(self: Addr) bool;
pub fn isUnspecified(self: Addr) bool;

pub fn next(self: Addr) ?Addr;
pub fn prev(self: Addr) ?Addr;

pub fn formatBuf(self: Addr, buf: []u8) !usize;
pub fn formatAllocate(self: Addr, allocator: std.mem.Allocator) ![]u8;
```

### AddrPort

Represents an IP address plus a port.

Target API shape:

```zig
const AddrPort = @This();

pub fn parse(s: []const u8) !AddrPort;
pub fn mustParse(comptime s: []const u8) AddrPort;
pub fn init(addr: Addr, port: u16) AddrPort;

pub fn addr(self: AddrPort) Addr;
pub fn port(self: AddrPort) u16;

pub fn format(self: AddrPort, writer: anytype) !void;
pub fn formatBuf(self: AddrPort, buf: []u8) ![]u8;
```

### Prefix

Represents CIDR-style address + prefix-length.

Target API shape:

```zig
const Prefix = @This();

pub fn parse(s: []const u8) !Prefix;
pub fn mustParse(comptime s: []const u8) Prefix;
pub fn init(addr: Addr, bits: u8) !Prefix;

pub fn addr(self: Prefix) Addr;
pub fn bits(self: Prefix) u8;
pub fn isValid(self: Prefix) bool;

pub fn masked(self: Prefix) Prefix;
pub fn contains(self: Prefix, addr: Addr) bool;
pub fn overlaps(a: Prefix, b: Prefix) bool;
pub fn isSingleIP(self: Prefix) bool;

pub fn format(self: Prefix, writer: anytype) !void;
pub fn formatBuf(self: Prefix, buf: []u8) ![]u8;
```

## Relationship with Go `net/netip`

The default rule for this package is:

- prefer matching Go over inventing a Zig-specific variant
- only diverge when Zig or embed-zig constraints make a direct match awkward
- document every intentional divergence clearly

Planned close matches:

- `Addr`
- `AddrPort`
- `Prefix`
- `Parse*` and `MustParse*`
- `Is4`, `Is6`, `Is4In6`
- `Unmap`
- `Contains`, `Masked`, `Overlaps`
- ordering helpers
- `Next` / `Prev`

Likely intentional differences:

1. Scope / zone handling.
   Go `netip.Addr` supports zone strings for scoped IPv6 addresses.
   embed-zig today already models IPv6 scope numerically in `Ip6Address`.
   If we cannot support zone strings cleanly in phase 1, this is the main
   place where an intentional mismatch may remain temporarily.

2. Formatting interface.
   Zig code should prefer `format(writer)` and `formatBuf(buf)` rather than
   requiring heap allocation for `String()`.

3. Marshaling helpers.
   Text/binary marshal helpers are useful, but they can wait until the core
   value semantics are stable.

## Conversions

This package should make conversions explicit and cheap:

```zig
pub fn fromAddress(addr: stdz.net.Address) AddrPort;
pub fn toAddress(self: AddrPort) stdz.net.Address;

pub fn fromIp4Address(addr: stdz.net.Ip4Address) Addr;
pub fn fromIp6Address(addr: stdz.net.Ip6Address) Addr;
```

Important rule:

- conversion APIs belong at the boundary
- internal `netip` logic should not depend on `posix.sockaddr`

## Internal representation

The representation should optimize for:

- comparability
- compact size
- branch-light classification
- allocator-free copies

A likely direction is:

```zig
const Addr = packed struct {
    bytes: [16]u8,
    kind: enum(u2) { invalid, v4, v6, v4_in_v6 },
    scope_id: u32,
};
```

This is only a sketch.

Before locking representation, we should confirm:

- desired map-key behavior
- whether `packed` actually helps here
- whether `v4_in_v6` deserves its own stored tag or should be derived

## Parsing and formatting rules

Phase 1 should support:

- IPv4 dotted decimal
- IPv6 compressed form
- IPv6 full form
- IPv4-mapped IPv6
- `AddrPort` bracket form for IPv6: `[::1]:443`
- CIDR prefix form: `2001:db8::/32`

Formatting should:

- emit canonical compressed IPv6
- use brackets for IPv6 host:port formatting
- match Go formatting rules as closely as possible

## Phase plan

### Phase 1

Ship the core value types:

- `Addr`
- `AddrPort`
- `Prefix`
- parse / format
- comparisons
- classification helpers
- conversions to/from `stdz.net.Address`

### Phase 2

Add convenience and ecosystem glue:

- more classification helpers
- text/binary marshal helpers
- richer tests against Go behavior
- route/filter helpers if still needed

### Phase 3

Start adopting `netip` across `lib/net`:

- resolver outputs and filters
- HTTP allow/deny lists
- future route / subnet aware APIs

## Testing strategy

The package should have three layers of tests:

1. Pure parsing/formatting examples.
2. Table-driven behavior parity tests against Go `net/netip`
   semantics and documented edge cases.
3. Conversion roundtrip tests with `stdz.net.Address`.

Key invariants:

- `parse(format(x)) == x` for valid canonical values
- `Prefix.masked().contains(addr)` behaves consistently for both v4 and v6
- `AddrPort.toAddress().fromAddress()` roundtrips without losing port or IP

## Initial deliverables

Recommended implementation order:

1. `netip/Addr.zig`
2. `netip/AddrPort.zig`
3. `netip/Prefix.zig`
4. `lib/net/netip.zig`
5. integrate docs into `lib/net/README.md`

## Example future usage

```zig
const netip = @import("net/netip.zig");

const addr = try netip.Addr.parse("192.168.1.10");
const ap = netip.AddrPort.init(addr, 443);
const lan = try netip.Prefix.parse("192.168.1.0/24");

if (lan.contains(addr)) {
    // local subnet
}
```

## Summary

`netip` should become the pure value layer for IP logic in embed-zig:

- `stdz.net.Address` stays the syscall/socket boundary type
- `netip` becomes the address math / prefix / config / comparison layer
- the package should follow Go `net/netip` first, not `std.net`

That mirrors the same split Go ended up with, and it fits the current
`lib/net` architecture well.
