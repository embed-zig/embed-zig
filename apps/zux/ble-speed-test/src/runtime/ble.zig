const consts = @import("../consts.zig");

const client_mod = @import("ble/client.zig");
const server_mod = @import("ble/server.zig");

pub fn make(comptime grt: type, comptime ZuxAppType: type, comptime role: consts.Role) type {
    return switch (role) {
        .client => client_mod.make(grt, ZuxAppType),
        .server => server_mod.make(grt, ZuxAppType),
    };
}
