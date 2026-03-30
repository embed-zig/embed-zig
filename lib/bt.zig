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
};

/// Build the built-in HCI-backed host bundle bound to `lib`.
///
/// Usage:
///   const HciHostType = bt.HciHost(embed, platform.Channel);
///   var host = try HciHostType.init(allocator, transport, .{});
///   defer host.deinit();
///
///   var central = host.central();
///   var peripheral = host.peripheral();
pub fn HciHost(comptime lib: type, comptime Channel: fn (type) type) type {
    const ConcreteHci = @import("bt/host/Hci.zig").Hci(lib);
    const HostType = @import("bt/Host.zig").Host(lib, Channel);
    const Allocator = lib.mem.Allocator;

    return struct {
        allocator: Allocator,
        hci: *ConcreteHci,
        host: HostType,

        const Self = @This();

        pub fn init(allocator: Allocator, transport: Transport, config: ConcreteHci.Config) !Self {
            const hci_ptr = try allocator.create(ConcreteHci);
            hci_ptr.* = ConcreteHci.init(transport, config);
            errdefer {
                hci_ptr.deinit();
                allocator.destroy(hci_ptr);
            }

            var host_impl = try HostType.init(Hci.wrap(hci_ptr), .{
                .allocator = allocator,
            });
            errdefer host_impl.deinit();

            return .{
                .allocator = allocator,
                .hci = hci_ptr,
                .host = host_impl,
            };
        }

        pub fn deinit(self: *Self) void {
            self.host.deinit();
            self.hci.deinit();
            self.allocator.destroy(self.hci);
        }

        pub fn central(self: *Self) Central {
            return self.host.central();
        }

        pub fn peripheral(self: *Self) Peripheral {
            return self.host.peripheral();
        }

        pub fn client(self: *Self) @TypeOf(self.host.client()) {
            return self.host.client();
        }

        pub fn server(self: *Self) @TypeOf(self.host.server()) {
            return self.host.server();
        }
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
    _ = @import("bt/host/client/xfer.zig");
    _ = @import("bt/host/Server.zig");
    _ = @import("bt/Host.zig");
}
