const glib = @import("glib");

pub const Central = @import("bt/Central.zig");
pub const Host = @import("bt/Host.zig");
pub const Peripheral = @import("bt/Peripheral.zig");
pub const GattConfig = Peripheral.GattConfig;
pub const Transport = @import("bt/Transport.zig");
pub const Hci = @import("bt/Hci.zig");
pub const Mocker = @import("bt/Mocker.zig").Mocker;
pub const test_runner = struct {
    pub const unit = @import("bt/test_runner/unit.zig");
    pub const integration = @import("bt/test_runner/integration.zig");
    pub const pair = @import("bt/test_runner/pair.zig");
    pub const pair_xfer = @import("bt/test_runner/pair_xfer.zig");
};

const Server = @import("bt/host/Server.zig");
const Client = @import("bt/host/Client.zig");

const bt = @This();

pub fn make(comptime grt: type) type {
    comptime {
        if (!glib.runtime.is(grt)) @compileError("bt.make requires a glib runtime namespace");
    }
    return struct {
        const self = @This();

        pub fn makeHost(comptime Impl: type) type {
            return bt.Host.make(grt, Impl);
        }
        pub const HciHost = bt.Host.makeHci(grt);
        pub const HciHostTransport = bt.Host.makeHciTransport(grt);
        pub const Server = bt.Server.make(grt);
        pub const Client = bt.Client.make(grt);
    };
}
