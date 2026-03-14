const std = @import("std");
const testing = std.testing;
const module = @import("rtc.zig");
const test_exports = if (@hasDecl(module, "test_exports")) module.test_exports else struct {};
const WriterError = module.WriterError;
const Timestamp = module.Timestamp;
const Datetime = module.Datetime;
const reader = module.reader;
const writer = module.writer;
const hal_marker = test_exports.hal_marker;
const msToSecsFloor = test_exports.msToSecsFloor;
const secsToMs = test_exports.secsToMs;

test "rtc conversion" {
    const epoch: i64 = 1769427296;
    const dt = Timestamp.fromEpoch(epoch).toDatetime();
    try std.testing.expectEqual(@as(u16, 2026), dt.year);
    try std.testing.expectEqual(epoch, dt.toEpoch());
}

test "rtc nowMs and Timestamp second semantics" {
    const MockDriver = struct {
        pub fn uptime(_: *@This()) u64 {
            return 1;
        }
        pub fn nowMs(_: *@This()) ?i64 {
            return 1_769_427_296_987;
        }
    };

    const Reader = reader.from(struct {
        pub const Driver = MockDriver;
        pub const meta = .{ .id = "rtc.reader" };
    });

    var d = MockDriver{};
    var r = Reader.init(&d);
    const ts = r.now() orelse return error.ExpectedTimestamp;
    try std.testing.expectEqual(@as(i64, 1_769_427_296), ts.toEpoch());
    try std.testing.expectEqual(@as(i64, 1_769_427_296_987), r.nowMs().?);
}

test "rtc writer converts seconds to milliseconds" {
    const MockDriver = struct {
        stored_ms: ?i64 = null,

        pub fn setNowMs(self: *@This(), epoch_ms: i64) WriterError!void {
            self.stored_ms = epoch_ms;
        }
    };

    const Writer = writer.from(struct {
        pub const Driver = MockDriver;
        pub const meta = .{ .id = "rtc.writer" };
    });

    var d = MockDriver{};
    var w = Writer.init(&d);
    try w.setTimestamp(Timestamp.fromEpoch(1_700_000_000));
    try std.testing.expectEqual(@as(?i64, 1_700_000_000_000), d.stored_ms);
}
