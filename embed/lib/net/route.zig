const glib = @import("glib");
const types = @import("types.zig");

pub const Default = struct {
    family: types.AddressFamily,
    interface_id: types.InterfaceId,
    gateway: ?glib.net.netip.Addr = null,
    metric: u32 = 0,
};
