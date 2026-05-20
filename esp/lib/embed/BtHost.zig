const embed = @import("embed_core");
const esp = @import("esp");

const Vhci = @import("bt/Vhci.zig");

const BtHost = @This();
const thread_allocator = esp.heap.Allocator(.{ .caps = .internal_8bit, .alignment = .align_u32 });

pub const Config = struct {
    allocator: esp.grt.std.mem.Allocator,
    source_id: u32 = 1,
};

allocator: esp.grt.std.mem.Allocator,
transport: *Vhci.Transport,
host: embed.bt.Host,

pub fn init(config: Config) !BtHost {
    try Vhci.init();
    const transport = try config.allocator.create(Vhci.Transport);
    errdefer config.allocator.destroy(transport);
    transport.* = Vhci.Transport.init();
    errdefer transport.deinit();

    const Host = embed.bt.Host.makeHciTransport(esp.grt);
    const host = try Host.init(config.allocator, transport.handle(), .{
        .hci = .{
            .spawn_config = .{
                .name = "bt_hci",
                .stack_size = 8 * 1024,
                .allocator = thread_allocator,
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
