# core_bluetooth — Apple CoreBluetooth backend for lib/bt

Implements `bt.Central` and `bt.Peripheral` by bridging to Apple's
CoreBluetooth framework (`CBCentralManager`, `CBPeripheralManager`)
via the Objective-C runtime.

This module lives under `embed-zig/pkg` and is exported by the top-level
`embed_zig` package as `core_bluetooth`. It links `CoreBluetooth.framework`,
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
app_mod.addImport("core_bluetooth", embed_dep.module("core_bluetooth"));
```

App code (host facade; see `lib/bt` in embed-zig for the full API):

```zig
const std = @import("std");
const embed = @import("embed");
const gstd = @import("gstd");
const cb = @import("core_bluetooth");

const Bt = embed.bt.make(gstd.runtime);
const Host = Bt.makeHost(cb.Host);

var host = try Host.init(undefined, .{ .allocator = allocator });
defer host.deinit();

var central = host.central();
try central.startScanning(.{ .active = true });
```

## Package structure

Tests follow the same `test_runner` layout as
[mbedz CoC §4.4](https://github.com/embed-zig/embed-zig) / `embed-zig-example`: only
top-level `test "..."` blocks live in `core_bluetooth.zig`; runners live under
`test_runner/` (`unit`, `integration`). This package does not ship empty benchmark/cork stubs.

```text
core_bluetooth.zig    Root module; bt.Host impl; pkg-level test blocks only
src/
  CBCentral.zig       bt.Central impl via CBCentralManager
  CBPeripheral.zig    bt.Peripheral impl via CBPeripheralManager
  objc.zig            Objective-C runtime helpers
test_runner/
  unit.zig            Unit runner (placeholder; no file-level TestRunners in src yet)
  integration.zig     Aggregates integration runners
  integration/
    central.zig
    peripheral.zig
    host_callback.zig
```

## CoreBluetooth mapping

### Central (CBCentralManager)

| bt.Central method   | CoreBluetooth API                                    |
|----------------------|------------------------------------------------------|
| startScanning        | scanForPeripheralsWithServices:options:               |
| stopScanning         | stopScan                                             |
| connect              | connectPeripheral:options:                           |
| disconnect           | cancelPeripheralConnection:                          |
| discoverServices     | CBPeripheral discoverServices:                       |
| discoverChars        | CBPeripheral discoverCharacteristics:forService:     |
| gattRead             | CBPeripheral readValueForCharacteristic:             |
| gattWrite            | CBPeripheral writeValue:forCharacteristic:type:      |
| subscribe            | CBPeripheral setNotifyValue:YES forCharacteristic:   |
| unsubscribe          | CBPeripheral setNotifyValue:NO forCharacteristic:    |
| getAddr              | N/A (CoreBluetooth does not expose local BD_ADDR)    |

### Peripheral (CBPeripheralManager)

| bt.Peripheral method | CoreBluetooth API                                    |
|----------------------|------------------------------------------------------|
| startAdvertising     | startAdvertising: (CBAdvertisementData dict)         |
| stopAdvertising      | stopAdvertising                                      |
| handle               | addService: (CBMutableService + CBMutableCharacteristic) |
| notify / indicate    | updateValue:forCharacteristic:onSubscribedCentrals:  |
| disconnect           | N/A (CBPeripheralManager cannot force-disconnect)    |
| getAddr              | N/A (CoreBluetooth does not expose local BD_ADDR)    |

### Event mapping

| bt.CentralEvent      | CoreBluetooth delegate callback                      |
|----------------------|------------------------------------------------------|
| device_found         | centralManager:didDiscoverPeripheral:advertisementData:RSSI: |
| connected            | centralManager:didConnectPeripheral:                 |
| disconnected         | centralManager:didDisconnectPeripheral:error:        |
| notification         | peripheral:didUpdateValueForCharacteristic:error:    |

| bt.PeripheralEvent   | CoreBluetooth delegate callback                      |
|----------------------|------------------------------------------------------|
| connected            | peripheralManager:central:didSubscribeToCharacteristic: |
| disconnected         | peripheralManager:central:didUnsubscribeFromCharacteristic: |
| advertising_started  | peripheralManagerDidStartAdvertising:error:           |
| mtu_changed          | peripheral:didOpenL2CAPChannel: (or maximumUpdateValueLength) |

### Blocking bridge

CoreBluetooth is callback-driven (delegate pattern on NSRunLoop).
The bridge translates this to bt's blocking model using a
Mutex + Condition pair: the calling thread blocks until the
delegate callback signals completion.
