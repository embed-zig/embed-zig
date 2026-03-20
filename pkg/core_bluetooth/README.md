# pkg/core_bluetooth — Apple CoreBluetooth backend for lib/bt

Implements `bt.Central` and `bt.Peripheral` by bridging to Apple's
CoreBluetooth framework (`CBCentralManager`, `CBPeripheralManager`)
via the Objective-C runtime.

This is a standalone Zig package that links `CoreBluetooth.framework`
and `Foundation.framework`. Only usable on Apple platforms (macOS, iOS).

## Usage

App's `build.zig.zon`:

```zig
.dependencies = .{
    .embed_zig = .{ .path = "path/to/embed-zig" },
    .core_bluetooth = .{ .path = "path/to/embed-zig/pkg/core_bluetooth" },
},
```

App's `build.zig`:

```zig
const bt_mod = embed_dep.module("bt");
const cb_mod = cb_dep.module("core_bluetooth");
app_mod.addImport("bt", bt_mod);
app_mod.addImport("core_bluetooth", cb_mod);
```

App code:

```zig
const cb = @import("core_bluetooth");

var central = try cb.Central(.{}).init(allocator);
defer central.deinit();
try central.start();

try central.startScanning(.{ .active = true });
```

## Package structure

```
pkg/core_bluetooth/
  build.zig             Build config; links CoreBluetooth + Foundation
  build.zig.zon         Depends on embed_zig (for bt VTable definitions)
  src/
    core_bluetooth.zig  Root module; re-exports Central and Peripheral
    CBCentral.zig       bt.Central impl via CBCentralManager
    CBPeripheral.zig    bt.Peripheral impl via CBPeripheralManager
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
