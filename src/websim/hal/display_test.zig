const std = @import("std");
const testing = std.testing;
const module = @import("display.zig");
const test_exports = if (@hasDecl(module, "test_exports")) module.test_exports else struct {};
const embed = struct {
    pub const hal = struct {
        pub const display = @import("../../hal/display.zig");
    };
};
const RemoteHal = @import("../remote_hal.zig").RemoteHal;
const Color565 = embed.hal.display.Color565;
const Display = module.Display;

test "websim display satisfies hal contract" {
    const router_mod = @import("../outbox.zig");

    var running = std.atomic.Value(bool){ .raw = true };
    var router = router_mod.DevRouter.init(std.testing.allocator);
    defer router.deinit();
    var bus = RemoteHal.initTest(&running, &router);
    const outbox = router.track("display");

    var drv = Display{ .bus = &bus, .width_px = 8, .height_px = 4 };
    const DisplayHal = embed.hal.display.from(struct {
        pub const Driver = Display;
        pub const meta = .{ .id = "display.websim" };
    });

    var display = DisplayHal.init(&drv);
    const pixels = [_]Color565{ 0x1111, 0x2222, 0x3333, 0x4444 };
    try display.drawBitmap(1, 1, 2, 2, &pixels);

    const state_msg = outbox.pop(10) orelse return error.ExpectedState;
    defer std.testing.allocator.free(state_msg);
    try std.testing.expect(std.mem.indexOf(u8, state_msg, "\"kind\":\"state\"") != null);

    const frame_msg = outbox.pop(10) orelse return error.ExpectedFrame;
    defer std.testing.allocator.free(frame_msg);
    try std.testing.expect(std.mem.indexOf(u8, frame_msg, "\"kind\":\"frame\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame_msg, "\"format\":\"rgb565le\"") != null);
}
