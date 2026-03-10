const board_hw = @import("board_hw");
const test_firmware = @import("test_firmware");

const rom_printf = struct {
    extern fn esp_rom_printf(fmt: [*:0]const u8, ...) c_int;
}.esp_rom_printf;

pub fn panic(msg: []const u8, _: ?*@import("std").builtin.StackTrace, _: ?usize) noreturn {
    _ = rom_printf("\n*** ZIG PANIC ***\n");
    if (msg.len > 0) {
        _ = rom_printf("%.*s\n", @as(c_int, @intCast(msg.len)), msg.ptr);
    }
    _ = rom_printf("*****************\n");
    while (true) {}
}

export fn zig_esp_main() callconv(.c) void {
    test_firmware.run(board_hw, .{});
}
