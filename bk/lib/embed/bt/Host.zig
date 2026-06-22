const embed = @import("embed_core");
const bk = @import("../../bk.zig");

pub fn make(comptime Hci: type) type {
    return struct {
        const Self = @This();

        pub const Config = struct {
            allocator: bk.ap.grt.std.mem.Allocator,
            source_id: u32 = 1,
        };

        allocator: bk.ap.grt.std.mem.Allocator,
        transport: *Hci.Transport,
        host: embed.bt.Host,

        pub fn init(config: Config) !Self {
            try Hci.init();
            const transport = try config.allocator.create(Hci.Transport);
            errdefer config.allocator.destroy(transport);
            transport.* = Hci.Transport.init();
            errdefer transport.deinit();

            const EmbedHost = embed.bt.Host.makeHciTransport(bk.ap.grt);
            const host = try EmbedHost.init(config.allocator, transport.handle(), .{
                .hci = .{
                    .task_options = .{
                        .min_stack_size = 8 * 1024,
                    },
                },
                .source_id = config.source_id,
            });
            return .{
                .allocator = config.allocator,
                .transport = transport,
                .host = host,
            };
        }

        pub fn deinit(self: *Self) void {
            self.host.deinit();
            self.transport.deinit();
            self.allocator.destroy(self.transport);
            self.* = undefined;
        }

        pub fn handle(self: *Self) embed.bt.Host {
            return self.host;
        }
    };
}
