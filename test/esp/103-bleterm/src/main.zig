const board_hw = @import("board_hw");
const app = @import("test_firmware");
const esp = @import("esp");
const bt = esp.component.bt;
const nvs_flash = esp.component.nvs_flash;

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
    nvs_flash.init() catch {
        nvs_flash.erase() catch return;
        nvs_flash.init() catch return;
    };

    bt.controller.init() catch {
        _ = rom_printf("bt controller init failed\n");
        return;
    };
    bt.controller.enable(.ble) catch {
        _ = rom_printf("bt controller enable failed\n");
        return;
    };

    app.run(board_hw, .{});
}
