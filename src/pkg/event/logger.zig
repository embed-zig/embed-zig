//! Event logger middleware — logs PeriphEvent fields from a tagged union.
//!
//! Usage:
//!   const LogMw = event.Logger(App.Event, Board.log, "button");
//!   rt.use(LogMw.middleware("raw"));
//!   rt.use(LogMw.middleware("gesture"));

const std = @import("std");
const middleware_mod = @import("middleware.zig");

pub fn Logger(comptime EventType: type, comptime Log: type, comptime field: []const u8) type {
    return struct {
        pub fn middleware(comptime tag: []const u8) middleware_mod.Middleware(EventType) {
            return .{
                .ctx = null,
                .processFn = struct {
                    fn process(_: ?*anyopaque, ev: EventType, emit_ctx: *anyopaque, emit: middleware_mod.EmitFn(EventType)) void {
                        switch (ev) {
                            inline else => |val, t| {
                                if (comptime std.mem.eql(u8, @tagName(t), field)) {
                                    const log: Log = .{};
                                    log.debugFmt("[" ++ tag ++ "] " ++ field ++ " id={s} code={d}", .{ val.id, val.code });
                                }
                            },
                        }
                        emit(emit_ctx, ev);
                    }
                }.process,
            };
        }
    };
}
