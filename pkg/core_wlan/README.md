# core_wlan — Apple CoreWLAN backend for drivers.wifi

Implements `drivers.wifi.Sta` on macOS by bridging to Apple's public CoreWLAN
framework (`CWWiFiClient`, `CWInterface`, `CWNetwork`) via the Objective-C
runtime.

This package intentionally does **not** implement SoftAP / hotspot hosting.
Apple does not provide a public macOS API for a general-purpose Wi-Fi AP
backend, so `drivers.wifi.Ap.start(...)` returns `error.Unsupported`.

This module lives under `embed-zig/pkg` and is exported by the top-level
`embed_zig` package as `core_wlan`. It links `CoreWLAN.framework`,
`Foundation.framework`, and `libobjc`.
**macOS / Apple targets only** (framework linking is gated on the OS tag).

## Developing

```bash
zig build
zig build test
```

## Usage as a dependency

`build.zig`:

```zig
const embed_dep = b.dependency("embed_zig", .{ .target = target, .optimize = optimize });

const app_mod = b.createModule(.{ ... });
app_mod.addImport("embed", embed_dep.module("embed"));
app_mod.addImport("gstd", embed_dep.module("gstd"));
app_mod.addImport("core_wlan", embed_dep.module("core_wlan"));
```

App code:

```zig
const std = @import("std");
const embed = @import("embed");
const gstd = @import("gstd");
const core_wlan = @import("core_wlan");

const CoreWlanWifi = embed.drivers.wifi.Wifi.make(gstd.runtime.std, core_wlan.Wifi);
const device = try CoreWlanWifi.init(.{
    .allocator = allocator,
    .source_id = 1,
});
defer device.deinit();

try device.sta().startScan(.{});
```

## Package structure

Top-level `test "..."` blocks live only in `core_wlan.zig`. Runners are under
`test_runner/` (`unit`, `integration`).

```text
core_wlan.zig Root module; pkg-level test blocks only
src/
  objc.zig
  CWSta.zig
  CWApUnsupported.zig
test_runner/
  unit.zig
  integration.zig
  integration/
    sta.zig
```

## Mapping

### `drivers.wifi.Sta`

| `drivers.wifi.Sta` method | CoreWLAN API |
|---|---|
| `startScan` | `-[CWInterface scanForNetworksWithName:includeHidden:error:]` |
| `connect` | `-[CWInterface associateToNetwork:password:error:]` |
| `disconnect` | `-[CWInterface disassociate]` |
| `getMacAddr` | `-[CWInterface hardwareAddress]` |

### `drivers.wifi.Ap`

`drivers.wifi.Ap.start(...)` returns `error.Unsupported`.

## Notes

- Package tests run both `std` and `embed_std` integration passes; only the `std`
  pass performs a real `startScan` probe, so two scans are not issued back-to-back
  against CoreWLAN in one `zig build test`.
- CoreWLAN scanning is synchronous and snapshot-based, so `startScan` performs a
  single scan and emits `scan_result` callbacks immediately.
- `getIpInfo()` is currently best-effort and returns `null`.
- Event hooks currently reflect operations initiated through this adapter; this
  package does not yet subscribe to broader system Wi-Fi notifications.
