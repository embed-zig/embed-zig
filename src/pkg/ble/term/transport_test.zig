const std = @import("std");
const testing = std.testing;
const module = @import("transport.zig");
const test_exports = if (@hasDecl(module, "test_exports")) module.test_exports else struct {};
const GattTransport = module.GattTransport;
const builtin = test_exports.builtin;
const TestMutex = test_exports.TestMutex;
const TestCond = test_exports.TestCond;
const testNotify = test_exports.testNotify;

test "GattTransport: push and recv" {
    const T = GattTransport(TestMutex, TestCond);
    var transport = T.init(testNotify, null);
    defer transport.deinit();

    try transport.push("hello");

    var buf: [64]u8 = undefined;
    const n = (try transport.recv(&buf, 100)).?;
    try std.testing.expectEqualSlices(u8, "hello", buf[0..n]);
}

test "GattTransport: recv timeout returns null" {
    const T = GattTransport(TestMutex, TestCond);
    var transport = T.init(testNotify, null);
    defer transport.deinit();

    var buf: [64]u8 = undefined;
    const result = try transport.recv(&buf, 1);
    try std.testing.expect(result == null);
}

test "GattTransport: multiple push/recv" {
    const T = GattTransport(TestMutex, TestCond);
    var transport = T.init(testNotify, null);
    defer transport.deinit();

    try transport.push("aaa");
    try transport.push("bbb");

    var buf: [64]u8 = undefined;
    const n1 = (try transport.recv(&buf, 100)).?;
    try std.testing.expectEqualSlices(u8, "aaa", buf[0..n1]);

    const n2 = (try transport.recv(&buf, 100)).?;
    try std.testing.expectEqualSlices(u8, "bbb", buf[0..n2]);
}

test "GattTransport: send calls notify_fn" {
    const Ctx = struct {
        called: bool = false,
        pub fn notify(ctx: ?*anyopaque, data: []const u8) anyerror!void {
            _ = data;
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.called = true;
        }
    };
    var ctx = Ctx{};
    const T = GattTransport(TestMutex, TestCond);
    var transport = T.init(Ctx.notify, @ptrCast(&ctx));
    defer transport.deinit();

    try transport.send("test");
    try std.testing.expect(ctx.called);
}

test "GattTransport: close wakes recv" {
    const T = GattTransport(TestMutex, TestCond);
    var transport = T.init(testNotify, null);
    defer transport.deinit();

    transport.close();

    var buf: [64]u8 = undefined;
    const result = transport.recv(&buf, 1000);
    try std.testing.expectError(error.Closed, result);
}

test "GattTransport: reset clears queue" {
    const T = GattTransport(TestMutex, TestCond);
    var transport = T.init(testNotify, null);
    defer transport.deinit();

    try transport.push("data");
    transport.reset();

    var buf: [64]u8 = undefined;
    const result = try transport.recv(&buf, 1);
    try std.testing.expect(result == null);
}
