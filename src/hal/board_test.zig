const std = @import("std");
const testing = std.testing;
const module = @import("board.zig");
const test_exports = if (@hasDecl(module, "test_exports")) module.test_exports else struct {};
const Board = module.Board;
const from = module.from;
const hal_marker = test_exports.hal_marker;
const rtc_mod = test_exports.rtc_mod;
const getMarkedKind = test_exports.getMarkedKind;
const findPeripheralType = test_exports.findPeripheralType;
const findRtcReaderType = test_exports.findRtcReaderType;
const driverTypeOf = test_exports.driverTypeOf;
const validatePeripheralType = test_exports.validatePeripheralType;
const driverInit = test_exports.driverInit;
const driverDeinit = test_exports.driverDeinit;

test "Board init/deinit with rtc and led" {
    const rtc_driver = struct {
        pub fn init() !@This() {
            return .{};
        }
        pub fn deinit(_: *@This()) void {}
        pub fn uptime(_: *@This()) u64 {
            return 123;
        }
        pub fn nowMs(_: *@This()) ?i64 {
            return 1_769_427_296_987;
        }
    };

    const rtc_spec = struct {
        pub const Driver = rtc_driver;
        pub const meta = .{ .id = "rtc.test" };
    };
    const Rtc = rtc_mod.reader.from(rtc_spec);

    const led_mod = @import("led.zig");
    const led_driver = struct {
        duty: u16 = 0,
        pub fn init() !@This() {
            return .{};
        }
        pub fn deinit(_: *@This()) void {}
        pub fn setDuty(self: *@This(), duty: u16) void {
            self.duty = duty;
        }
        pub fn getDuty(self: *const @This()) u16 {
            return self.duty;
        }
        pub fn fade(self: *@This(), duty: u16, _: u32) void {
            self.duty = duty;
        }
    };
    const led_spec = struct {
        pub const Driver = led_driver;
        pub const meta = .{ .id = "led.test" };
    };
    const Led = led_mod.from(led_spec);

    const board_spec = struct {
        pub const meta = .{ .id = "board.test" };
        pub const rtc = Rtc;
        pub const led = Led;
    };

    const TestBoard = Board(board_spec);

    var board: TestBoard = undefined;
    try board.init();
    defer board.deinit();

    try std.testing.expectEqual(@as(u64, 123), board.uptime());
    const now_ts = board.now() orelse return error.ExpectedNow;
    try std.testing.expectEqual(@as(i64, 1_769_427_296), now_ts.toEpoch());
}
