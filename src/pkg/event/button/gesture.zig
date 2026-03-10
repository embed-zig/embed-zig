//! Button gesture middleware — recognizes click (with consecutive count) and
//! long-press from raw press/release events.
//!
//! Generic over EventType and tag. Intercepts events matching `tag` with
//! press (code=1) and release (code=2), and emits higher-level gesture
//! events back into the same tag. Non-matching events pass through unchanged.
//!
//! Gesture codes emitted:
//!   click      = 3   (data = consecutive click count: 1, 2, 3, ...)
//!   long_press = 5

const std = @import("std");
const event_pkg = struct {
    pub const types = @import("../types.zig");

    pub fn Middleware(comptime EventType: type) type {
        return @import("../middleware.zig").Middleware(EventType);
    }

    pub fn EmitFn(comptime EventType: type) type {
        return @import("../middleware.zig").EmitFn(EventType);
    }
};

pub const GestureCode = enum(u16) {
    press = 1,
    release = 2,
    click = 3,
    long_press = 5,
};

pub const GestureConfig = struct {
    long_press_ms: u64 = 500,
    multi_click_window_ms: u64 = 300,
};

pub fn ButtonGesture(comptime EventType: type, comptime tag: []const u8, comptime Time: type) type {
    comptime event_pkg.types.assertTaggedUnion(EventType);

    const MiddlewareType = event_pkg.Middleware(EventType);
    const EmitFnType = event_pkg.EmitFn(EventType);
    const Tag = std.meta.Tag(EventType);

    return struct {
        const Self = @This();

        config: GestureConfig,
        time: Time,
        mw: MiddlewareType,

        pending_press: ?PendingPress,
        pending_clicks: ?PendingClicks,

        const PendingPress = struct {
            id: []const u8,
            press_ms: u64,
        };

        const PendingClicks = struct {
            id: []const u8,
            last_click_ms: u64,
            count: u16,
        };

        pub fn init(time: Time, config: GestureConfig) Self {
            return .{
                .config = config,
                .time = time,
                .mw = undefined,
                .pending_press = null,
                .pending_clicks = null,
            };
        }

        pub fn middleware(self: *Self) MiddlewareType {
            self.mw = .{
                .ctx = self,
                .processFn = processEvent,
                .tickFn = tickEvent,
            };
            return self.mw;
        }

        fn processEvent(ctx: ?*anyopaque, ev: EventType, emit_ctx: *anyopaque, emit: EmitFnType) void {
            const self: *Self = @ptrCast(@alignCast(ctx orelse {
                emit(emit_ctx, ev);
                return;
            }));

            if (std.meta.activeTag(ev) == @field(Tag, tag)) {
                const payload = @field(ev, tag);
                const code = payload.code;
                if (code == @intFromEnum(GestureCode.press)) {
                    self.onPress(payload.id);
                } else if (code == @intFromEnum(GestureCode.release)) {
                    self.onRelease(payload.id, emit_ctx, emit);
                } else {
                    emit(emit_ctx, ev);
                }
            } else {
                emit(emit_ctx, ev);
            }
        }

        fn tickEvent(ctx: ?*anyopaque, _: u64, emit_ctx: *anyopaque, emit: EmitFnType) void {
            const self: *Self = @ptrCast(@alignCast(ctx orelse return));
            const now = self.time.nowMs();

            if (self.pending_press) |pp| {
                if (now >= pp.press_ms + self.config.long_press_ms) {
                    emitGesture(emit_ctx, emit, pp.id, .long_press, 0);
                    self.pending_press = null;
                    self.pending_clicks = null;
                }
            }

            if (self.pending_clicks) |pc| {
                if (now >= pc.last_click_ms + self.config.multi_click_window_ms) {
                    emitGesture(emit_ctx, emit, pc.id, .click, pc.count);
                    self.pending_clicks = null;
                }
            }
        }

        fn onPress(self: *Self, id: []const u8) void {
            const now = self.time.nowMs();
            self.pending_press = .{ .id = id, .press_ms = now };
        }

        fn onRelease(self: *Self, id: []const u8, emit_ctx: *anyopaque, emit: EmitFnType) void {
            const now = self.time.nowMs();

            const pp = self.pending_press orelse return;
            if (!strEql(pp.id, id)) return;

            const hold_ms = now -| pp.press_ms;
            self.pending_press = null;

            if (hold_ms >= self.config.long_press_ms) {
                emitGesture(emit_ctx, emit, id, .long_press, 0);
                self.pending_clicks = null;
                return;
            }

            if (self.pending_clicks) |*pc| {
                if (strEql(pc.id, id) and now -| pc.last_click_ms < self.config.multi_click_window_ms) {
                    pc.count += 1;
                    pc.last_click_ms = now;
                    return;
                }
            }

            self.pending_clicks = .{ .id = id, .last_click_ms = now, .count = 1 };
        }

        fn emitGesture(emit_ctx: *anyopaque, emit: EmitFnType, id: []const u8, code: GestureCode, data: u16) void {
            emit(emit_ctx, @unionInit(EventType, tag, .{
                .id = id,
                .code = @intFromEnum(code),
                .data = @intCast(data),
            }));
        }

        fn strEql(a: []const u8, b: []const u8) bool {
            return std.mem.eql(u8, a, b);
        }
    };
}
