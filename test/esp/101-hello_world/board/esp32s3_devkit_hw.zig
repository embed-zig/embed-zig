const esp_rt = @import("esp").runtime;
const esp_hal = @import("esp").hal;
const esp_rom = @import("esp").component.esp_rom;

pub const name: []const u8 = "esp32s3_devkit";

pub fn init() !void {}
pub fn deinit() void {}

pub const rtc_spec = struct {
    pub const Driver = esp_hal.RtcReader.DriverType;
    pub const meta = .{ .id = "rtc.esp_timer" };
};

fn printMsg(prefix: [*:0]const u8, msg: []const u8) void {
    esp_rom.printf("%s", .{prefix});
    for (msg) |c| esp_rom.printf("%c", .{c});
    esp_rom.printf("\n", .{});
}

pub const log = struct {
    pub fn debug(_: @This(), msg: []const u8) void {
        printMsg("[D] ", msg);
    }
    pub fn info(_: @This(), msg: []const u8) void {
        printMsg("[I] ", msg);
    }
    pub fn warn(_: @This(), msg: []const u8) void {
        printMsg("[W] ", msg);
    }
    pub fn err(_: @This(), msg: []const u8) void {
        printMsg("[E] ", msg);
    }
};

pub const time = esp_rt.Time;
