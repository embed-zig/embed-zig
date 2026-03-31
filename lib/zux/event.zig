pub const Context = @import("event/Context.zig");
pub const button = @import("event/button.zig");
pub const bluetooth = @import("event/bluetooth.zig");
pub const imu = @import("event/imu.zig");
pub const nfc = @import("event/nfc.zig");
pub const wifi = @import("event/wifi.zig");

pub const Button = button.Button;
pub const ButtonGroup = button.ButtonGroup;
pub const Bluetooth = bluetooth;
pub const Accel = imu.Accel;
pub const Gyro = imu.Gyro;
pub const NfcRead = nfc.NfcRead;
pub const Wifi = wifi;

test {
    _ = @import("event/Context.zig");
    _ = @import("event/bluetooth/CentralScanStart.zig");
    _ = @import("event/bluetooth/CentralScanStop.zig");
    _ = @import("event/bluetooth/CentralConnect.zig");
    _ = @import("event/bluetooth/CentralDisconnect.zig");
    _ = @import("event/bluetooth/PeripheralAdvertiseStart.zig");
    _ = @import("event/bluetooth/PeripheralAdvertiseStop.zig");
    _ = @import("event/wifi/StaScanStart.zig");
    _ = @import("event/wifi/StaScanStop.zig");
    _ = @import("event/wifi/StaConnect.zig");
    _ = @import("event/wifi/StaConnected.zig");
    _ = @import("event/wifi/StaDisconnect.zig");
    _ = @import("event/wifi/StaDisconnected.zig");
    _ = @import("event/wifi/ApStart.zig");
    _ = @import("event/wifi/ApStop.zig");
    _ = @import("event/button/Button.zig");
    _ = @import("event/button/ButtonGroup.zig");
    _ = @import("event/imu/Accel.zig");
    _ = @import("event/imu/Gyro.zig");
    _ = @import("event/nfc/NfcRead.zig");
}
