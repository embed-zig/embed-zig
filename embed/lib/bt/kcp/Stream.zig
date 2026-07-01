const glib = @import("glib");

const Config = @import("Config.zig");
const session_mod = @import("Session.zig");

pub fn Stream(comptime grt: type, comptime kcp: type) type {
    const Session = session_mod.Session(grt, kcp);

    return struct {
        allocator: glib.std.mem.Allocator,
        session: *Session,
        cleanup_ctx: ?*anyopaque = null,
        before_session_deinit_fn: ?*const fn (?*anyopaque) void = null,
        cleanup_fn: ?*const fn (?*anyopaque) void = null,

        const Self = @This();

        pub const Error = Session.Error;
        pub const Stats = session_mod.Stats;

        pub fn init(
            allocator: glib.std.mem.Allocator,
            config: Config,
            output_ctx: ?*anyopaque,
            output_fn: Session.OutputFn,
        ) !*Self {
            return initWithLifecycle(allocator, config, output_ctx, output_fn, null, null);
        }

        pub fn initWithCleanup(
            allocator: glib.std.mem.Allocator,
            config: Config,
            output_ctx: ?*anyopaque,
            output_fn: Session.OutputFn,
            cleanup_fn: ?*const fn (?*anyopaque) void,
        ) !*Self {
            return initWithLifecycle(allocator, config, output_ctx, output_fn, null, cleanup_fn);
        }

        pub fn initWithLifecycle(
            allocator: glib.std.mem.Allocator,
            config: Config,
            output_ctx: ?*anyopaque,
            output_fn: Session.OutputFn,
            before_session_deinit_fn: ?*const fn (?*anyopaque) void,
            cleanup_fn: ?*const fn (?*anyopaque) void,
        ) !*Self {
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);
            self.* = .{
                .allocator = allocator,
                .session = try Session.init(allocator, config, output_ctx, output_fn),
                .cleanup_ctx = output_ctx,
                .before_session_deinit_fn = before_session_deinit_fn,
                .cleanup_fn = cleanup_fn,
            };
            return self;
        }

        pub fn deinit(self: *Self) void {
            self.session.close();
            if (self.before_session_deinit_fn) |before_session_deinit| before_session_deinit(self.cleanup_ctx);
            self.session.deinit();
            if (self.cleanup_fn) |cleanup| cleanup(self.cleanup_ctx);
            const allocator = self.allocator;
            self.* = undefined;
            allocator.destroy(self);
        }

        pub fn close(self: *Self) void {
            self.session.close();
        }

        pub fn input(self: *Self, data: []const u8) Error!void {
            return self.session.input(data);
        }

        pub fn write(self: *Self, data: []const u8) Error!void {
            return self.session.write(data);
        }

        pub fn writeTimeout(self: *Self, data: []const u8, timeout: glib.time.duration.Duration) Error!bool {
            return self.session.writeTimeout(data, timeout);
        }

        pub fn read(self: *Self, out: []u8) Error!usize {
            return self.session.read(out);
        }

        pub fn readTimeout(self: *Self, out: []u8, timeout: glib.time.duration.Duration) Error!?usize {
            return self.session.recvTimeout(out, timeout);
        }

        pub fn stats(self: *const Self) Stats {
            return self.session.stats();
        }
    };
}
