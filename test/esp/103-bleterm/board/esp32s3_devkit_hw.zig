const esp_rt = @import("esp").runtime;
const esp_hal = @import("esp").hal;
const esp_heap = @import("esp").component.heap;

pub const name: []const u8 = "esp32s3_devkit";

pub const allocator = struct {
    pub const user = esp_heap.psram;
    pub const system = esp_heap.dram;
    pub const default = esp_heap.default;
};

pub const thread = struct {
    pub const Thread = esp_rt.Thread;
    pub const user_defaults = .{
        .allocator = esp_heap.psram,
        .priority = @as(u8, 3),
        .name = @as([*:0]const u8, "user"),
        .core_id = @as(?i32, 0),
    };
    pub const system_defaults = .{
        .allocator = esp_heap.dram,
        .priority = @as(u8, 5),
        .name = @as([*:0]const u8, "sys"),
    };
    pub const default_defaults = .{
        .allocator = esp_heap.default,
        .priority = @as(u8, 5),
        .name = @as([*:0]const u8, "zig-task"),
    };
};

pub const log = esp_rt.Log;
pub const time = esp_rt.Time;

pub const sync = struct {
    pub const Mutex = esp_rt.Mutex;
    pub const Condition = esp_rt.Condition;
};

pub const ble_hci_spec = struct {
    pub const Driver = esp_hal.Hci.DriverType;
    pub const meta = .{ .id = "hci.esp32s3" };
};

pub const rtc_spec = struct {
    pub const Driver = esp_hal.RtcReader.DriverType;
    pub const meta = .{ .id = "rtc.devkit" };
};
