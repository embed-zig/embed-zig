const route = @import("route.zig");
const types = @import("types.zig");

pub const AddressChange = struct {
    interface_id: types.InterfaceId,
    address: types.AddressInfo,
};

pub const Event = union(enum) {
    iface_up: types.InterfaceId,
    iface_down: types.InterfaceId,
    address_added: AddressChange,
    address_removed: AddressChange,
    default_route_changed: route.Default,
};

pub const CallbackFn = *const fn (ctx: *const anyopaque, event: Event) void;
