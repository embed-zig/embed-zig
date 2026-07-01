const glib = @import("glib");

const bt = @import("../../bt.zig");
const Config = @import("Config.zig");
const stream_mod = @import("Stream.zig");

pub fn make(comptime grt: type, comptime raw_kcp: type) type {
    const Stream = stream_mod.Stream(grt, raw_kcp);
    const AcceptChannel = grt.sync.Channel(*Stream);

    return struct {
        pub const KcpStream = Stream;
        pub const Handler = struct {
            onStream: *const fn (ctx: ?*anyopaque, stream: *Stream) anyerror!void,
        };

        pub const Endpoint = struct {
            allocator: glib.std.mem.Allocator,
            config: Config,
            handler: Handler,
            ctx: ?*anyopaque,
            accept_ch: AcceptChannel,
            server: ?*anyopaque = null,
            mutex: grt.sync.Mutex = .{},
            active_stream: ?*Stream = null,

            const Self = @This();

            pub fn init(allocator: glib.std.mem.Allocator, options: struct {
                service_uuid: u16 = Config.DEFAULT_SERVICE_UUID,
                tx_char_uuid: u16,
                rx_char_uuid: u16,
                conv: u32 = Config.DEFAULT_CONV,
                att_mtu: u16 = 23,
                handler: Handler,
                ctx: ?*anyopaque = null,
                task_options: glib.task.Options = .{ .min_stack_size = 12 * 1024 },
            }) !Self {
                return .{
                    .allocator = allocator,
                    .config = .{
                        .service_uuid = options.service_uuid,
                        .tx_char_uuid = options.tx_char_uuid,
                        .rx_char_uuid = options.rx_char_uuid,
                        .conv = options.conv,
                        .att_mtu = options.att_mtu,
                        .task_options = options.task_options,
                    },
                    .handler = options.handler,
                    .ctx = options.ctx,
                    .accept_ch = try AcceptChannel.make(allocator, 1),
                };
            }

            pub fn deinit(self: *Self) void {
                self.accept_ch.close();
                self.clearActive();
                self.accept_ch.deinit();
            }

            pub fn handle(self: *Self, server: anytype) !void {
                self.server = server;
                const ServerPtr = @TypeOf(server);
                const ServerType = switch (@typeInfo(ServerPtr)) {
                    .pointer => |ptr| ptr.child,
                    else => @compileError("bt.kcp.server.Endpoint.handle expects a server pointer"),
                };
                const Subscription = ServerType.Subscription;
                const Callbacks = struct {
                    fn onSubscription(ctx: ?*anyopaque, subscription: Subscription) void {
                        const endpoint: *Self = @ptrCast(@alignCast(ctx.?));
                        endpoint.accept(subscription);
                    }
                };
                try server.handle(self.config.service_uuid, self.config.tx_char_uuid, .{
                    .onSubscription = Callbacks.onSubscription,
                }, self);
                try server.handle(self.config.service_uuid, self.config.rx_char_uuid, .{
                    .onRequest = onRequest,
                }, self);
            }

            pub fn run(self: *Self) !void {
                while (true) {
                    const accepted = self.accept_ch.recv() catch break;
                    if (!accepted.ok) break;
                    self.handler.onStream(self.ctx, accepted.value) catch {};
                    self.clearIfActive(accepted.value);
                }
            }

            fn accept(self: *Self, subscription: anytype) void {
                self.config.att_mtu = subscription.attMtu();
                const Output = struct {
                    allocator: glib.std.mem.Allocator,
                    sub: @TypeOf(subscription),

                    fn write(ctx: ?*anyopaque, data: []const u8) anyerror!void {
                        const output: *@This() = @ptrCast(@alignCast(ctx.?));
                        return output.sub.write(data);
                    }

                    fn cleanup(ctx: ?*anyopaque) void {
                        const output: *@This() = @ptrCast(@alignCast(ctx.?));
                        output.sub.deinit();
                        const allocator = output.allocator;
                        output.* = undefined;
                        allocator.destroy(output);
                    }
                };

                const output = self.allocator.create(Output) catch {
                    var sub = subscription;
                    sub.deinit();
                    return;
                };
                output.* = .{
                    .allocator = self.allocator,
                    .sub = subscription,
                };
                const stream = Stream.initWithCleanup(self.allocator, self.config, output, Output.write, Output.cleanup) catch {
                    self.allocator.destroy(output);
                    var sub = subscription;
                    sub.deinit();
                    return;
                };
                self.setActive(stream);
                const sent = self.accept_ch.send(stream) catch {
                    self.clearIfActive(stream);
                    stream.deinit();
                    return;
                };
                if (!sent.ok) {
                    self.clearIfActive(stream);
                    stream.deinit();
                }
            }

            fn feedInput(self: *Self, data: []const u8) void {
                self.mutex.lock();
                const stream = self.active_stream;
                self.mutex.unlock();
                if (stream) |active| active.input(data) catch {};
            }

            fn setActive(self: *Self, stream: *Stream) void {
                self.mutex.lock();
                self.active_stream = stream;
                self.mutex.unlock();
            }

            fn clearIfActive(self: *Self, stream: *Stream) void {
                self.mutex.lock();
                if (self.active_stream == stream) self.active_stream = null;
                self.mutex.unlock();
            }

            fn clearActive(self: *Self) void {
                self.mutex.lock();
                self.active_stream = null;
                self.mutex.unlock();
            }

            fn onRequest(ctx: ?*anyopaque, req: *const bt.Peripheral.Request, rw: *bt.Peripheral.ResponseWriter) void {
                const self: *Self = @ptrCast(@alignCast(ctx.?));
                if (req.op == .read) {
                    rw.err(0x06);
                    return;
                }
                self.feedInput(req.data);
                if (req.op == .write) rw.ok();
            }
        };
    };
}
