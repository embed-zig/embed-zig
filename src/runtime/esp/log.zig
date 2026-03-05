const std = @import("std");
const esp = @import("esp");

pub const Log = struct {
    pub fn debug(_: Log, msg: []const u8) void {
        printTagged("[debug]", msg);
    }

    pub fn info(_: Log, msg: []const u8) void {
        printTagged("[info]", msg);
    }

    pub fn warn(_: Log, msg: []const u8) void {
        printTagged("[warn]", msg);
    }

    pub fn err(_: Log, msg: []const u8) void {
        printTagged("[error]", msg);
    }
};

fn printTagged(comptime tag: [*:0]const u8, msg: []const u8) void {
    const max_len: usize = @intCast(std.math.maxInt(c_int));
    const len: c_int = @intCast(@min(msg.len, max_len));
    esp.esp_rom.printf("%s %.*s\n", .{ tag, len, msg.ptr });
}
