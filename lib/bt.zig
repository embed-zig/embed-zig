pub const Central = @import("bt/Central.zig");
pub const Host = @import("bt/Host.zig");
pub const Peripheral = @import("bt/Peripheral.zig");
pub const GattConfig = Peripheral.GattConfig;
pub const Transport = @import("bt/Transport.zig");
pub const Hci = @import("bt/Hci.zig");
pub const Mocker = @import("bt/Mocker.zig").Mocker;
pub const test_runner = struct {
    pub const central = @import("bt/test_runner/central.zig");
    pub const peripheral = @import("bt/test_runner/peripheral.zig");
    pub const pair = @import("bt/test_runner/pair.zig");
    pub const pair_xfer = @import("bt/test_runner/pair_xfer.zig");
    pub const xfer = @import("bt/test_runner/xfer.zig");
};

const Server = @import("bt/host/Server.zig");
const Client = @import("bt/host/Client.zig");

pub const server = struct {
    pub const ServeMux = @import("bt/host/server/ServeMux.zig");
    pub const Receiver = @import("bt/host/server/Receiver.zig");
};

const bt = @This();

pub fn make(comptime lib: type, comptime Channel: fn (type) type) type {
    return struct {
        const self = @This();

        pub fn makeHost(comptime Impl: type) type {
            return bt.Host.make(lib, Impl, Channel);
        }
        pub const HciHost = bt.Host.makeHci(lib, Channel);
        pub const HciHostTransport = bt.Host.makeHciTransport(lib, Channel);
        pub const Server = bt.Server.make(lib, Channel);
        pub const Client = bt.Client.make(lib);
        pub const ServeMux = bt.server.ServeMux.make(lib, self.Server);
        pub const Receiver = bt.server.Receiver.make(lib, self.Server);
    };
}

test "bt/unit_tests" {
    _ = @import("bt/host/hci/status.zig");
    _ = @import("bt/host/hci/commands.zig");
    _ = @import("bt/host/hci/events.zig");
    _ = @import("bt/host/hci/acl.zig");
    _ = @import("bt/host/l2cap.zig");
    _ = @import("bt/host/att.zig");
    _ = @import("bt/host/Gap.zig");
    _ = @import("bt/host/gatt/server.zig");
    _ = @import("bt/host/gatt/client.zig");
    _ = @import("bt/host/Central.zig");
    _ = @import("bt/host/Peripheral.zig");
    _ = @import("bt/host/Server.zig");
    _ = @import("bt/Host.zig");
}
