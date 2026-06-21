const embed = @import("embed_core");
const esp = @import("esp");

const LocalHci = @import("bt/LocalHci.zig");

const BtHost = @This();

pub const Config = struct {
    allocator: esp.grt.std.mem.Allocator,
    source_id: u32 = 1,
};

allocator: esp.grt.std.mem.Allocator,
transport: *LocalHci.Transport,
host: embed.bt.Host,

pub fn init(config: Config) !BtHost {
    try LocalHci.init();
    const transport = try config.allocator.create(LocalHci.Transport);
    errdefer config.allocator.destroy(transport);
    transport.* = LocalHci.Transport.init();
    errdefer transport.deinit();

    const Host = embed.bt.Host.makeHciTransport(esp.grt);
    const host = try Host.init(config.allocator, transport.handle(), .{
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

pub fn deinit(self: *BtHost) void {
    self.host.deinit();
    self.transport.deinit();
    self.allocator.destroy(self.transport);
    self.* = undefined;
}

pub fn handle(self: *BtHost) embed.bt.Host {
    return self.host;
}
