//! CWApUnsupported — macOS CoreWLAN does not expose public SoftAP support.

const std = @import("std");
const wifi = @import("wifi");
const Ap = wifi.Ap;
const Allocator = std.mem.Allocator;

const CWApUnsupported = @This();

allocator: Allocator,

pub const Config = struct {};

pub fn init(allocator: Allocator, _: Config) CWApUnsupported {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *CWApUnsupported) void {
    const alloc = self.allocator;
    self.* = undefined;
    alloc.destroy(self);
}

pub fn start(self: *CWApUnsupported, _: Ap.Config) Ap.StartError!void {
    _ = self;
    return error.Unsupported;
}

pub fn stop(self: *CWApUnsupported) void {
    _ = self;
}

pub fn disconnectClient(self: *CWApUnsupported, _: Ap.MacAddr) void {
    _ = self;
}

pub fn getState(self: *CWApUnsupported) Ap.State {
    _ = self;
    return .idle;
}

pub fn addEventHook(self: *CWApUnsupported, _: ?*anyopaque, _: *const fn (?*anyopaque, Ap.Event) void) void {
    _ = self;
}

pub fn removeEventHook(self: *CWApUnsupported, _: ?*anyopaque, _: *const fn (?*anyopaque, Ap.Event) void) void {
    _ = self;
}

pub fn getMacAddr(self: *CWApUnsupported) ?Ap.MacAddr {
    _ = self;
    return null;
}

test "core_wlan/unit_tests/ap_backend_reports_unsupported" {
    var backend = CWApUnsupported.init(std.testing.allocator, .{});
    try std.testing.expectError(error.Unsupported, backend.start(.{
        .ssid = "test-ap",
    }));
}
