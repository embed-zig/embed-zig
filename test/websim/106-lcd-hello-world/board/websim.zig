const std = @import("std");
const embed = @import("embed");
const runtime = embed.runtime;
const websim = embed.websim;
const RemoteHal = websim.RemoteHal;

pub threadlocal var session_bus: ?*RemoteHal = null;
pub threadlocal var session_running: ?*std.atomic.Value(bool) = null;

pub const SessionCtx = struct {};

pub const SessionSetup = struct {
    pub fn setup(bus: *RemoteHal, running: *std.atomic.Value(bool)) SessionCtx {
        session_bus = bus;
        session_running = running;
        return .{};
    }

    pub fn bind(_: *SessionCtx, _: *RemoteHal) void {}

    pub fn teardown(_: *SessionCtx) void {
        session_bus = null;
        session_running = null;
    }
};

pub const hw = struct {
    pub const name: []const u8 = "websim.106";

    pub const allocator = struct {
        pub const user = std.heap.page_allocator;
        pub const system = std.heap.page_allocator;
        pub const default = std.heap.page_allocator;
    };

    pub const log = runtime.std.Log;
    pub const time = runtime.std.Time;

    pub const isRunning = struct {
        fn check() bool {
            const r = session_running orelse return false;
            return r.load(.acquire);
        }
    }.check;

    pub const rtc_spec = struct {
        pub const Driver = websim.hal.Rtc;
        pub const meta = .{ .id = "rtc.websim" };
    };

    pub const display_spec = struct {
        pub const Driver = struct {
            inner: websim.hal.Display,

            const Self = @This();

            pub fn init() embed.hal.display.Error!Self {
                return .{
                    .inner = .{
                        .bus = session_bus,
                        .width_px = 320,
                        .height_px = 240,
                    },
                };
            }

            pub fn deinit(_: *Self) void {}

            pub fn width(self: *const Self) u16 {
                return self.inner.width();
            }

            pub fn height(self: *const Self) u16 {
                return self.inner.height();
            }

            pub fn setDisplayEnabled(self: *Self, enabled: bool) embed.hal.display.Error!void {
                return self.inner.setDisplayEnabled(enabled);
            }

            pub fn sleep(self: *Self, enabled: bool) embed.hal.display.Error!void {
                return self.inner.sleep(enabled);
            }

            pub fn drawBitmap(
                self: *Self,
                x: u16,
                y: u16,
                w: u16,
                h: u16,
                data: []const embed.hal.display.Color565,
            ) embed.hal.display.Error!void {
                return self.inner.drawBitmap(x, y, w, h, data);
            }
        };

        pub const meta = .{ .id = "display.websim" };
    };
};
