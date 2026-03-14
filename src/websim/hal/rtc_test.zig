const std = @import("std");
const testing = std.testing;
const module = @import("rtc.zig");
const test_exports = if (@hasDecl(module, "test_exports")) module.test_exports else struct {};
const embed = struct {
    pub const hal = struct {
        pub const rtc = @import("../../hal/rtc.zig");
    };
};
const Rtc = module.Rtc;

test "websim rtc satisfies hal contract" {
    const RtcReader = embed.hal.rtc.reader.from(struct {
        pub const Driver = Rtc;
        pub const meta = .{ .id = "rtc.websim" };
    });

    var drv = Rtc.init();
    var r = RtcReader.init(&drv);

    const up = r.uptime();
    try std.testing.expect(up < 1000);

    const ms = r.nowMs();
    try std.testing.expect(ms != null);
    try std.testing.expect(ms.? > 0);
    try std.testing.expect(r.isSynced());
}
