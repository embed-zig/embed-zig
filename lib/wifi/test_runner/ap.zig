//! Wi-Fi AP smoke test runner — exercises the portable `wifi.Ap` surface.
//!
//! By default this runner only verifies safe introspection and hook
//! registration. Optional AP start probing is opt-in so normal test runs
//! do not attempt to reconfigure host networking.

const embed = @import("embed");
const testing_api = @import("testing");
const wifi = @import("../../wifi.zig");

pub const Options = struct {
    probe_start: bool = false,
    config: wifi.Ap.Config = .{
        .ssid = "embed-zig-test",
    },
};

pub fn make(comptime lib: type, device: anytype) testing_api.TestRunner {
    return makeWithOptions(lib, device, .{});
}

pub fn makeWithOptions(comptime lib: type, device: anytype, options: Options) testing_api.TestRunner {
    const DevicePtr = @TypeOf(device);
    comptime requireDevicePointer(DevicePtr);

    const Runner = struct {
        device: DevicePtr,
        options: Options,

        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: embed.mem.Allocator) bool {
            _ = allocator;
            runSurface(lib, self.device, self.options) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: embed.mem.Allocator) void {
            _ = allocator;
            lib.testing.allocator.destroy(self);
        }
    };

    const runner = lib.testing.allocator.create(Runner) catch @panic("OOM");
    runner.* = .{
        .device = device,
        .options = options,
    };
    return testing_api.TestRunner.make(Runner).new(runner);
}

pub fn runSurface(comptime lib: type, device: anytype, options: Options) !void {
    const testing = lib.testing;
    const ApHook = struct {
        fn cb(ctx: ?*anyopaque, _: wifi.Ap.Event) void {
            const counter: *lib.atomic.Value(u32) = @ptrCast(@alignCast(ctx.?));
            _ = counter.fetchAdd(1, .monotonic);
        }
    };

    const ap = device.ap();
    try expectValidState(ap.getState());
    _ = ap.getMacAddr();

    var hook_count = lib.atomic.Value(u32).init(0);
    ap.addEventHook(@ptrCast(&hook_count), ApHook.cb);
    defer ap.removeEventHook(@ptrCast(&hook_count), ApHook.cb);

    if (options.probe_start) {
        const before_probe = hook_count.load(.acquire);
        var start_supported = true;
        ap.start(options.config) catch |err| switch (err) {
            error.Unsupported => start_supported = false,
            else => return err,
        };
        if (ap.getState() == .active or ap.getState() == .starting) {
            ap.stop();
        }
        try expectValidState(ap.getState());
        const after_probe = hook_count.load(.acquire);
        if (start_supported) {
            try testing.expect(after_probe > before_probe);
        }
    }

    _ = hook_count.load(.acquire);
}

fn expectValidState(state: wifi.Ap.State) !void {
    switch (state) {
        .idle, .starting, .active => {},
    }
}

fn requireDevicePointer(comptime T: type) void {
    if (@typeInfo(T) != .pointer) {
        @compileError("ap runner expects *Wifi-like instance");
    }
}

test "wifi/unit_tests/ap_runner_keeps_hook_installed_during_probe" {
    const std = @import("std");

    const Impl = struct {
        state: wifi.Ap.State = .idle,
        hook_ctx: ?*anyopaque = null,
        hook_cb: ?*const fn (?*anyopaque, wifi.Ap.Event) void = null,
        saw_hook_during_start: bool = false,

        pub fn start(self: *@This(), cfg: wifi.Ap.Config) wifi.Ap.StartError!void {
            _ = cfg;
            self.saw_hook_during_start = self.hook_cb != null;
            self.state = .active;
            if (self.hook_cb) |cb| cb(self.hook_ctx, .{ .started = .{
                .ssid = "embed-zig-test",
                .channel = 1,
                .security = .wpa2,
            } });
        }

        pub fn stop(self: *@This()) void {
            self.state = .idle;
            if (self.hook_cb) |cb| cb(self.hook_ctx, .{ .stopped = {} });
        }

        pub fn disconnectClient(self: *@This(), _: wifi.Ap.MacAddr) void {
            _ = self;
        }

        pub fn getState(self: *@This()) wifi.Ap.State {
            return self.state;
        }

        pub fn addEventHook(self: *@This(), ctx: ?*anyopaque, cb: *const fn (?*anyopaque, wifi.Ap.Event) void) void {
            self.hook_ctx = ctx;
            self.hook_cb = cb;
        }

        pub fn removeEventHook(self: *@This(), ctx: ?*anyopaque, cb: *const fn (?*anyopaque, wifi.Ap.Event) void) void {
            if (self.hook_ctx == ctx and self.hook_cb == cb) {
                self.hook_ctx = null;
                self.hook_cb = null;
            }
        }

        pub fn getMacAddr(self: *@This()) ?wifi.Ap.MacAddr {
            _ = self;
            return null;
        }

        pub fn deinit(self: *@This()) void {
            _ = self;
        }
    };

    const Device = struct {
        impl: *Impl,

        pub fn ap(self: *@This()) wifi.Ap {
            return wifi.Ap.make(self.impl);
        }
    };

    var impl = Impl{};
    var device = Device{ .impl = &impl };
    try runSurface(std, &device, .{
        .probe_start = true,
    });
    try std.testing.expect(impl.saw_hook_during_start);
}
