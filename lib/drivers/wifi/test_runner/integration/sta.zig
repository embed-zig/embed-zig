//! Wi-Fi STA smoke test runner — exercises the portable `wifi.Sta` surface.
//!
//! By default this runner performs one real scan in addition to safe
//! introspection and hook registration. Callers can disable scan probing
//! explicitly when they need a non-invasive surface-only check.

const embed = @import("embed");
const testing_api = @import("testing");
const wifi = @import("../../../wifi.zig");

pub const Options = struct {
    probe_scan: bool = true,
    require_scan_event: bool = false,
    scan_config: wifi.Sta.ScanConfig = .{},
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
    const StaHook = struct {
        fn cb(ctx: ?*anyopaque, _: wifi.Sta.Event) void {
            const counter: *lib.atomic.Value(u32) = @ptrCast(@alignCast(ctx.?));
            _ = counter.fetchAdd(1, .monotonic);
        }
    };

    const sta = device.sta();
    try expectValidState(sta.getState());
    _ = sta.getMacAddr();
    _ = sta.getIpInfo();

    var hook_count = lib.atomic.Value(u32).init(0);
    sta.addEventHook(@ptrCast(&hook_count), StaHook.cb);
    defer sta.removeEventHook(@ptrCast(&hook_count), StaHook.cb);

    if (options.probe_scan) {
        const before_scan = hook_count.load(.acquire);
        sta.startScan(options.scan_config) catch |err| switch (err) {
            error.Busy => {},
            else => return err,
        };
        if (sta.getState() == .scanning) {
            sta.stopScan();
        }
        try expectValidState(sta.getState());
        const after_scan = hook_count.load(.acquire);
        if (options.require_scan_event) {
            try testing.expect(after_scan > before_scan);
        }
    }

    _ = hook_count.load(.acquire);
}

fn expectValidState(state: wifi.Sta.State) !void {
    switch (state) {
        .idle, .scanning, .connecting, .connected => {},
    }
}

fn requireDevicePointer(comptime T: type) void {
    if (@typeInfo(T) != .pointer) {
        @compileError("sta runner expects *Wifi-like instance");
    }
}

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    const TestCase = struct {
        fn runnerObservesScanEventsWhenRequired() !void {
            const Impl = struct {
                state: wifi.Sta.State = .idle,
                hook_ctx: ?*anyopaque = null,
                hook_cb: ?*const fn (?*anyopaque, wifi.Sta.Event) void = null,

                pub fn startScan(self: *@This(), cfg: wifi.Sta.ScanConfig) wifi.Sta.ScanError!void {
                    _ = cfg;
                    self.state = .scanning;
                    if (self.hook_cb) |cb| cb(self.hook_ctx, .{ .scan_result = .{
                        .ssid = "lab-net",
                        .bssid = .{ 1, 2, 3, 4, 5, 6 },
                        .channel = 6,
                        .rssi = -40,
                        .security = .wpa2,
                    } });
                    self.state = .idle;
                }

                pub fn stopScan(self: *@This()) void {
                    self.state = .idle;
                }

                pub fn connect(self: *@This(), _: wifi.Sta.ConnectConfig) wifi.Sta.ConnectError!void {
                    _ = self;
                }

                pub fn disconnect(self: *@This()) void {
                    _ = self;
                }

                pub fn getState(self: *@This()) wifi.Sta.State {
                    return self.state;
                }

                pub fn addEventHook(self: *@This(), ctx: ?*anyopaque, cb: *const fn (?*anyopaque, wifi.Sta.Event) void) void {
                    self.hook_ctx = ctx;
                    self.hook_cb = cb;
                }

                pub fn removeEventHook(self: *@This(), ctx: ?*anyopaque, cb: *const fn (?*anyopaque, wifi.Sta.Event) void) void {
                    if (self.hook_ctx == ctx and self.hook_cb == cb) {
                        self.hook_ctx = null;
                        self.hook_cb = null;
                    }
                }

                pub fn getMacAddr(self: *@This()) ?wifi.Sta.MacAddr {
                    _ = self;
                    return null;
                }

                pub fn getIpInfo(self: *@This()) ?wifi.Sta.IpInfo {
                    _ = self;
                    return null;
                }

                pub fn deinit(self: *@This()) void {
                    _ = self;
                }
            };

            const Device = struct {
                impl: *Impl,

                pub fn sta(self: *@This()) wifi.Sta {
                    return wifi.Sta.make(self.impl);
                }
            };

            var impl = Impl{};
            var device = Device{ .impl = &impl };
            try runSurface(lib, &device, .{
                .probe_scan = true,
                .require_scan_event = true,
            });
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: embed.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            TestCase.runnerObservesScanEventsWhenRequired() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: embed.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}
