//! core_wlan — Apple CoreWLAN backend for lib/wifi.
//!
//! Implements a `wifi.Wifi`-compatible backend with:
//! - `wifi.Sta` backed by CoreWLAN on macOS
//! - `wifi.Ap` reporting `error.Unsupported`

const std = @import("std");
const wifi = @import("wifi");
const CWSta = @import("core_wlan/src/CWSta.zig");
const CWApUnsupported = @import("core_wlan/src/CWApUnsupported.zig");

pub const Sta = CWSta;
pub const Ap = CWApUnsupported;

pub const Wifi = struct {
    pub const StaConfig = CWSta.Config;
    pub const ApConfig = CWApUnsupported.Config;
    pub const Config = struct {
        allocator: std.mem.Allocator,
        source_id: u32 = 0,
        sta: StaConfig = .{},
        ap: ApConfig = .{},
    };

    sta_impl: *CWSta,
    ap_impl: *CWApUnsupported,
    source_id: u32,
    callback_ctx: ?*const anyopaque = null,
    callback_fn: ?wifi.Wifi.CallbackFn = null,
    callback_installed: bool = false,

    const Self = @This();

    pub fn init(config: Config) !Self {
        const sta_impl = try config.allocator.create(CWSta);
        errdefer config.allocator.destroy(sta_impl);
        sta_impl.* = CWSta.init(config.allocator, config.sta);

        const ap_impl = try config.allocator.create(CWApUnsupported);
        errdefer sta_impl.deinit();
        ap_impl.* = CWApUnsupported.init(config.allocator, config.ap);

        return .{
            .sta_impl = sta_impl,
            .ap_impl = ap_impl,
            .source_id = config.source_id,
        };
    }

    pub fn deinit(self: *Self) void {
        self.clearEventCallback();
        self.sta_impl.deinit();
        self.ap_impl.deinit();
    }

    pub fn sta(self: *Self) wifi.Sta {
        return wifi.Sta.make(self.sta_impl);
    }

    pub fn ap(self: *Self) wifi.Ap {
        return wifi.Ap.make(self.ap_impl);
    }

    pub fn setEventCallback(self: *Self, ctx: *const anyopaque, emit_fn: wifi.Wifi.CallbackFn) void {
        self.callback_ctx = ctx;
        self.callback_fn = emit_fn;

        if (!self.callback_installed) {
            self.sta().addEventHook(self, onStaEvent);
            self.ap().addEventHook(self, onApEvent);
            self.callback_installed = true;
        }
    }

    pub fn clearEventCallback(self: *Self) void {
        if (self.callback_installed) {
            self.sta().removeEventHook(self, onStaEvent);
            self.ap().removeEventHook(self, onApEvent);
            self.callback_installed = false;
        }
        self.callback_ctx = null;
        self.callback_fn = null;
    }

    fn emitEvent(self: *Self, event: wifi.Wifi.Event) void {
        const ctx = self.callback_ctx orelse return;
        const emit_fn = self.callback_fn orelse return;
        emit_fn(ctx, self.source_id, event);
    }

    fn onStaEvent(ctx: ?*anyopaque, event: wifi.Sta.Event) void {
        const self: *Self = @ptrCast(@alignCast(ctx.?));
        self.emitEvent(.{ .sta = event });
    }

    fn onApEvent(ctx: ?*anyopaque, event: wifi.Ap.Event) void {
        const self: *Self = @ptrCast(@alignCast(ctx.?));
        self.emitEvent(.{ .ap = event });
    }
};

test "core_wlan/unit_tests" {
    const Impl = Wifi;
    comptime {
        _ = wifi.Wifi.make(std, Impl).init;
        _ = Wifi.sta;
        _ = Wifi.ap;
        _ = Wifi.setEventCallback;
        _ = Wifi.clearEventCallback;
    }
}

test "core_wlan/unit_tests/Wifi_forwards_sta_events_through_top_level_callback" {
    const Sink = struct {
        hits: usize = 0,
        last_source_id: u32 = 0,
        saw_sta_event: bool = false,

        fn cb(ctx: *const anyopaque, source_id: u32, event: wifi.Wifi.Event) void {
            const self: *@This() = @ptrCast(@alignCast(@constCast(ctx)));
            self.hits += 1;
            self.last_source_id = source_id;
            self.saw_sta_event = switch (event) {
                .sta => true,
                else => false,
            };
        }
    };

    var device = try Wifi.init(.{
        .allocator = std.testing.allocator,
        .source_id = 41,
    });
    defer device.deinit();

    var sink = Sink{};
    device.setEventCallback(@ptrCast(&sink), Sink.cb);
    Wifi.onStaEvent(@ptrCast(&device), .{ .lost_ip = {} });
    try std.testing.expectEqual(@as(usize, 1), sink.hits);
    try std.testing.expectEqual(@as(u32, 41), sink.last_source_id);
    try std.testing.expect(sink.saw_sta_event);

    device.clearEventCallback();
    Wifi.onStaEvent(@ptrCast(&device), .{ .lost_ip = {} });
    try std.testing.expectEqual(@as(usize, 1), sink.hits);
}

test "core_wlan/integration_tests" {
    _ = @import("core_wlan/integration_test/sta.zig");
}
