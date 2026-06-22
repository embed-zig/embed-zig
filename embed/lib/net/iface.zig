const glib = @import("glib");
const types = @import("types.zig");

pub const max_name_len: usize = 32;
pub const max_addresses_per_interface: usize = 4;

pub const Flags = struct {
    up: bool = false,
    running: bool = false,
    loopback: bool = false,
    default: bool = false,
};

pub const Info = struct {
    id: types.InterfaceId = 0,
    name_buf: [max_name_len]u8 = [_]u8{0} ** max_name_len,
    name_len: u8 = 0,
    flags: Flags = .{},
    addresses_buf: [max_addresses_per_interface]types.AddressInfo = undefined,
    address_count: u8 = 0,

    pub fn init(id: types.InterfaceId, value: []const u8) types.Error!Info {
        var info = Info{ .id = id };
        try info.setName(value);
        return info;
    }

    pub fn name(self: *const Info) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    pub fn setName(self: *Info, value: []const u8) types.Error!void {
        if (value.len > self.name_buf.len) return error.BufferTooSmall;
        @memset(&self.name_buf, 0);
        @memcpy(self.name_buf[0..value.len], value);
        self.name_len = @intCast(value.len);
    }

    pub fn addresses(self: *const Info) []const types.AddressInfo {
        return self.addresses_buf[0..self.address_count];
    }

    pub fn appendAddress(self: *Info, address: types.AddressInfo) types.Error!void {
        if (self.address_count >= self.addresses_buf.len) return error.BufferTooSmall;
        self.addresses_buf[self.address_count] = address;
        self.address_count += 1;
    }
};

pub fn findByName(items: []const Info, needle: []const u8) ?Info {
    for (items) |item| {
        if (glib.std.mem.eql(u8, item.name(), needle)) return item;
    }
    return null;
}

pub fn findById(items: []const Info, id: types.InterfaceId) ?Info {
    for (items) |item| {
        if (item.id == id) return item;
    }
    return null;
}
