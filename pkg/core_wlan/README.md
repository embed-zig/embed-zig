# pkg/core_wlan — Apple CoreWLAN backend for drivers.wifi

Implements `drivers.wifi.Sta` on macOS by bridging to Apple's public CoreWLAN
framework (`CWWiFiClient`, `CWInterface`, `CWNetwork`) via the Objective-C
runtime.

This package intentionally does **not** implement SoftAP / hotspot hosting.
Apple does not provide a public macOS API for a general-purpose Wi-Fi AP
backend, so `drivers.wifi.Ap.start(...)` returns `error.Unsupported`.

## Usage

App's `build.zig`:

```zig
const drivers_mod = embed_dep.module("drivers");
const core_wlan_mod = embed_dep.module("core_wlan");
app_mod.addImport("drivers", drivers_mod);
app_mod.addImport("core_wlan", core_wlan_mod);
```

App code:

```zig
const std = @import("std");
const drivers = @import("drivers");
const core_wlan = @import("core_wlan");

const CoreWlanWifi = drivers.wifi.Wifi.make(std, core_wlan.Wifi);
const device = try CoreWlanWifi.init(.{
    .allocator = allocator,
    .source_id = 1,
});
defer device.deinit();

try device.sta().startScan(.{});
```

## Package structure

```text
pkg/core_wlan/
  README.md
  src/
    objc.zig
    CWSta.zig
    CWApUnsupported.zig
pkg/core_wlan.zig
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

- CoreWLAN scanning is synchronous and snapshot-based, so `startScan` performs a
  single scan and emits `scan_result` callbacks immediately.
- `getIpInfo()` is currently best-effort and returns `null`.
- Event hooks currently reflect operations initiated through this adapter; this
  package does not yet subscribe to broader system Wi-Fi notifications.
