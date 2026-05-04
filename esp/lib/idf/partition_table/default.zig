const schema = @import("schema.zig");

const entries = [_]schema.Partition{
    .{ .name = "nvs", .kind = .data, .subtype = .nvs, .offset = 0x9000, .size = 0x6000 },
    .{ .name = "phy_init", .kind = .data, .subtype = .phy, .offset = 0xf000, .size = 0x1000 },
    .{ .name = "factory", .kind = .app, .subtype = .factory, .offset = 0x10000, .size = 0x100000 },
};

pub const table: schema.Table = .{
    .offset = 0x8000,
    .entries = &entries,
};
