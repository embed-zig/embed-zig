const glib = @import("glib");

const Config = @import("Config.zig");
const stream_mod = @import("Stream.zig");

pub fn make(comptime grt: type, comptime raw_kcp: type) type {
    const Stream = stream_mod.Stream(grt, raw_kcp);

    return struct {
        pub const OpenConfig = Config;
        pub const OpenError = anyerror;

        pub fn openStream(
            allocator: glib.std.mem.Allocator,
            client: anytype,
            conn_handle: u16,
            config: OpenConfig,
        ) OpenError!*Stream {
            var tx = client.resolveCharacteristic(conn_handle, config.service_uuid, config.tx_char_uuid) catch |err| return err;
            const rx = client.resolveCharacteristic(conn_handle, config.service_uuid, config.rx_char_uuid) catch |err| return err;
            var sub = try tx.subscribe();
            errdefer sub.deinit();

            const AtomicBool = grt.std.atomic.Value(bool);
            const Output = struct {
                allocator: glib.std.mem.Allocator,
                rx_char: @TypeOf(rx),
                subscription: @TypeOf(sub),
                stream: ?*Stream = null,
                closing: AtomicBool = AtomicBool.init(false),
                feeder: ?grt.task.Handle = null,

                fn write(ctx: ?*anyopaque, data: []const u8) anyerror!void {
                    const self: *@This() = @ptrCast(@alignCast(ctx.?));
                    return self.rx_char.writeNoResp(data);
                }

                fn run(self: *@This()) void {
                    while (!self.closing.load(.acquire)) {
                        const maybe = self.subscription.next(10 * glib.time.duration.MilliSecond) catch |err| switch (@as(anyerror, err)) {
                            error.TimedOut => continue,
                            else => break,
                        };
                        const msg = maybe orelse break;
                        const stream = self.stream orelse break;
                        stream.input(msg.payload()) catch break;
                    }
                }

                fn stopFeeder(ctx: ?*anyopaque) void {
                    const self: *@This() = @ptrCast(@alignCast(ctx.?));
                    self.closing.store(true, .release);
                    if (self.feeder) |feeder| feeder.join();
                }

                fn cleanup(ctx: ?*anyopaque) void {
                    const self: *@This() = @ptrCast(@alignCast(ctx.?));
                    self.subscription.deinit();
                    const owned_allocator = self.allocator;
                    self.* = undefined;
                    owned_allocator.destroy(self);
                }
            };

            const output = try allocator.create(Output);
            errdefer allocator.destroy(output);
            output.* = .{
                .allocator = allocator,
                .rx_char = rx,
                .subscription = sub,
            };

            const stream = try Stream.initWithLifecycle(allocator, config, output, Output.write, Output.stopFeeder, Output.cleanup);
            errdefer stream.deinit();
            output.stream = stream;
            output.feeder = try grt.task.go("bt/kcp/client/feed", config.task_options, glib.task.Routine.init(output, Output.run));
            return stream;
        }
    };
}
