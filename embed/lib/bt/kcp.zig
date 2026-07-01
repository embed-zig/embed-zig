const glib = @import("glib");

pub const Config = @import("kcp/Config.zig");
pub const session = @import("kcp/Session.zig");
pub const stream = @import("kcp/Stream.zig");
pub const client = @import("kcp/client.zig");
pub const server = @import("kcp/server.zig");

pub fn make(comptime grt: type, comptime raw_kcp: type) type {
    const KcpConfig = @import("kcp/Config.zig");
    return struct {
        pub const Config = KcpConfig;
        pub const Stream = stream.Stream(grt, raw_kcp);
        pub const Session = session.Session(grt, raw_kcp);
        pub const client = @import("kcp/client.zig").make(grt, raw_kcp);
        pub const server = @import("kcp/server.zig").make(grt, raw_kcp);

        pub fn makeStream(
            allocator: glib.std.mem.Allocator,
            config: KcpConfig,
            output_ctx: ?*anyopaque,
            output_fn: Session.OutputFn,
        ) !*Stream {
            return Stream.init(allocator, config, output_ctx, output_fn);
        }
    };
}
