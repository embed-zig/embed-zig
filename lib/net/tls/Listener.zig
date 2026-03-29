const NetConn = @import("../Conn.zig");
const NetListener = @import("../Listener.zig");
const server_conn_impl = @import("ServerConn.zig");

pub fn Listener(comptime lib: type) type {
    const Allocator = lib.mem.Allocator;
    const SC = server_conn_impl.ServerConn(lib);

    return struct {
        pub const Config = SC.Config;
        pub const Certificate = SC.Certificate;
        pub const PrivateKey = SC.PrivateKey;
        pub const InitError = Allocator.Error || SC.HandshakeError;

        allocator: Allocator,
        inner: NetListener,
        config: Config,
        closed: bool = false,

        const Self = @This();

        pub fn init(allocator: Allocator, inner: NetListener, config: Config) InitError!NetListener {
            try SC.validateConfig(config);
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);
            self.* = .{
                .allocator = allocator,
                .inner = inner,
                .config = config,
            };
            return NetListener.init(self);
        }

        pub fn listen(self: *Self) NetListener.ListenError!void {
            if (self.closed) return error.SocketNotListening;
            try self.inner.listen();
        }

        pub fn accept(self: *Self) NetListener.AcceptError!NetConn {
            if (self.closed) return error.SocketNotListening;

            const conn = self.inner.accept() catch |err| return err;
            errdefer conn.deinit();

            return SC.init(self.allocator, conn, self.config) catch return error.Unexpected;
        }

        pub fn close(self: *Self) void {
            if (self.closed) return;
            self.closed = true;
            self.inner.close();
        }

        pub fn deinit(self: *Self) void {
            if (!self.closed) self.inner.close();
            self.inner.deinit();
            self.allocator.destroy(self);
        }
    };
}
