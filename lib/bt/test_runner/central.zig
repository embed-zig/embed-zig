//! Central test runner — exercises bt.Central through the VTable interface.
//!
//! Tests lifecycle, scanning with various configs, event hooks, and
//! error conditions. Does NOT require a paired Peripheral — all tests
//! exercise the local Central state machine only.
//!
//! `runWithPeer` is provided separately for integration tests that
//! have a real Peripheral available.
//!
//! Usage:
//!   const runner = @import("bt/test_runner/central.zig");
//!   test { try runner.run(std, my_central); }

const Central = @import("../Central.zig");

pub fn run(comptime lib: type, c: Central) !void {
    const testing = lib.testing;

    // ---- initial state ----
    try testing.expectEqual(Central.State.idle, c.getState());
    _ = c.getAddr();

    // ---- scan: active, default config ----
    try c.startScanning(.{ .active = true, .timeout_ms = 1000 });
    try testing.expectEqual(Central.State.scanning, c.getState());
    c.stopScanning();
    try testing.expectEqual(Central.State.idle, c.getState());

    // ---- scan: passive ----
    try c.startScanning(.{ .active = false, .timeout_ms = 1000 });
    try testing.expectEqual(Central.State.scanning, c.getState());
    c.stopScanning();
    try testing.expectEqual(Central.State.idle, c.getState());

    // ---- scan: with service UUID filter (16-bit) ----
    try c.startScanning(.{
        .active = true,
        .timeout_ms = 1000,
        .service_uuids = &.{0x180D},
    });
    try testing.expectEqual(Central.State.scanning, c.getState());
    c.stopScanning();

    // ---- scan: multiple service UUID filters ----
    try c.startScanning(.{
        .active = true,
        .timeout_ms = 1000,
        .service_uuids = &.{ 0x180D, 0x180F, 0xFFE0 },
    });
    try testing.expectEqual(Central.State.scanning, c.getState());
    c.stopScanning();

    // ---- scan: allow duplicates ----
    try c.startScanning(.{
        .active = true,
        .timeout_ms = 1000,
        .filter_duplicates = false,
    });
    try testing.expectEqual(Central.State.scanning, c.getState());
    c.stopScanning();

    // ---- scan: custom interval/window ----
    try c.startScanning(.{
        .active = true,
        .timeout_ms = 1000,
        .interval_ms = 100,
        .window_ms = 50,
    });
    try testing.expectEqual(Central.State.scanning, c.getState());
    c.stopScanning();

    // ---- stop scanning while idle (no-op) ----
    try testing.expectEqual(Central.State.idle, c.getState());
    c.stopScanning();
    try testing.expectEqual(Central.State.idle, c.getState());

    // ---- event hook: register single hook ----
    var hook_called = lib.atomic.Value(bool).init(false);
    c.addEventHook(@ptrCast(&hook_called), struct {
        fn cb(ctx: ?*anyopaque, _: Central.CentralEvent) void {
            const flag: *lib.atomic.Value(bool) = @ptrCast(@alignCast(ctx.?));
            flag.store(true, .release);
        }
    }.cb);

    // ---- event hook: register multiple hooks ----
    var hook2_called = lib.atomic.Value(bool).init(false);
    c.addEventHook(@ptrCast(&hook2_called), struct {
        fn cb(ctx: ?*anyopaque, _: Central.CentralEvent) void {
            const flag: *lib.atomic.Value(bool) = @ptrCast(@alignCast(ctx.?));
            flag.store(true, .release);
        }
    }.cb);

    // ---- scan → stop → scan cycle (re-entrant) ----
    try c.startScanning(.{ .active = true, .timeout_ms = 500 });
    try testing.expectEqual(Central.State.scanning, c.getState());
    c.stopScanning();
    try testing.expectEqual(Central.State.idle, c.getState());
    try c.startScanning(.{ .active = true, .timeout_ms = 500 });
    try testing.expectEqual(Central.State.scanning, c.getState());
    c.stopScanning();
    try testing.expectEqual(Central.State.idle, c.getState());

    // ---- final state: idle ----
    try testing.expectEqual(Central.State.idle, c.getState());
}

pub fn runWithPeer(comptime lib: type, c: Central, peer_addr: Central.BdAddr) !void {
    const testing = lib.testing;
    try testing.expectEqual(Central.State.idle, c.getState());

    try c.connect(peer_addr, .public, .{});
    try testing.expectEqual(Central.State.connected, c.getState());

    var svcs: [8]Central.DiscoveredService = undefined;
    const svc_count = try c.discoverServices(0x0040, &svcs);
    try testing.expect(svc_count > 0);

    var chars: [8]Central.DiscoveredChar = undefined;
    const char_count = try c.discoverChars(0x0040, svcs[0].start_handle, svcs[0].end_handle, &chars);
    try testing.expect(char_count > 0);

    var buf: [64]u8 = undefined;
    const read_len = try c.gattRead(0x0040, chars[0].value_handle, &buf);
    try testing.expect(read_len > 0);

    try c.gattWrite(0x0040, chars[0].value_handle, "test");

    if (chars[0].cccd_handle != 0) {
        try c.subscribe(0x0040, chars[0].cccd_handle);
        try c.unsubscribe(0x0040, chars[0].cccd_handle);
    }

    c.disconnect(0x0040);
    try testing.expectEqual(Central.State.idle, c.getState());
}
