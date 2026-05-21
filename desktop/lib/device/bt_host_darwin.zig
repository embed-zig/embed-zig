const core_bluetooth = @import("core_bluetooth");
const embed = @import("embed");
const glib = @import("glib");
const gstd = @import("gstd");

const BtHost = @This();
const Bt = embed.bt.make(gstd.runtime);
const Host = Bt.makeHost(core_bluetooth.Host);

pub const Config = Host.Config;

host: embed.bt.Host,

pub fn init(allocator: glib.std.mem.Allocator, config: Config) !BtHost {
    return .{
        .host = try Host.init(undefined, withAllocator(allocator, config)),
    };
}

pub fn deinit(self: *BtHost) void {
    self.host.deinit();
    self.* = undefined;
}

pub fn handle(self: *BtHost) embed.bt.Host {
    return self.host;
}

fn withAllocator(allocator: glib.std.mem.Allocator, config: Config) Config {
    var next = config;
    next.allocator = allocator;
    return next;
}
