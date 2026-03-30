//! bt.Host — generic host bundle type constructor.

const root = @import("../bt.zig");
const Central = @import("host/Central.zig").Central;
const Client = @import("host/Client.zig").Client;
const Peripheral = @import("host/Peripheral.zig").Peripheral;
const Server = @import("host/Server.zig").Server;

pub fn make(comptime lib: type, comptime Impl: type, comptime Channel: fn (type) type) type {
    comptime {
        if (!@hasDecl(Impl, "Config")) @compileError("Host impl must define Config");
        if (!@hasDecl(Impl, "init")) @compileError("Host impl must define init");
        if (!@hasDecl(Impl, "deinit")) @compileError("Host impl must define deinit");
        if (!@hasDecl(Impl, "central")) @compileError("Host impl must define central");
        if (!@hasDecl(Impl, "peripheral")) @compileError("Host impl must define peripheral");
        if (!@hasField(Impl.Config, "allocator")) @compileError("Host impl Config must define allocator");

        _ = @as(*const fn (root.Hci, Impl.Config) anyerror!Impl, &Impl.init);
        _ = @as(*const fn (*Impl) void, &Impl.deinit);
        _ = @as(*const fn (*Impl) root.Central, &Impl.central);
        _ = @as(*const fn (*Impl) root.Peripheral, &Impl.peripheral);
    }

    const ClientImpl = Client(lib, root.Central);
    const ServerImpl = Server(lib, Channel, root.Peripheral);

    return struct {
        impl: Impl,
        client_impl: ClientImpl,
        server_impl: ServerImpl,
        central_view: root.Central,
        peripheral_view: root.Peripheral,

        const Self = @This();
        pub const Config = Impl.Config;

        pub fn init(hci: root.Hci, config: Config) !Self {
            var impl = try Impl.init(hci, config);
            errdefer impl.deinit();
            return .{
                .impl = impl,
                .client_impl = ClientImpl.init(config.allocator),
                .server_impl = try ServerImpl.init(config.allocator),
                .central_view = impl.central(),
                .peripheral_view = impl.peripheral(),
            };
        }

        pub fn deinit(self: *Self) void {
            self.client_impl.deinit();
            self.server_impl.deinit();
            self.impl.deinit();
        }

        pub fn central(self: *Self) root.Central {
            return self.impl.central();
        }

        pub fn peripheral(self: *Self) root.Peripheral {
            return self.impl.peripheral();
        }

        pub fn client(self: *Self) *ClientImpl {
            self.central_view = self.impl.central();
            self.client_impl.bind(&self.central_view);
            return &self.client_impl;
        }

        pub fn server(self: *Self) *ServerImpl {
            self.peripheral_view = self.impl.peripheral();
            self.server_impl.bind(&self.peripheral_view);
            return &self.server_impl;
        }
    };
}

pub fn Host(comptime lib: type, comptime Channel: fn (type) type) type {
    const CentralImpl = Central(lib);
    const PeripheralImpl = Peripheral(lib);
    const Allocator = lib.mem.Allocator;

    const Impl = struct {
        pub const Config = struct {
            allocator: Allocator,
        };

        central_impl: CentralImpl,
        peripheral_impl: PeripheralImpl,

        const Self = @This();

        pub fn init(hci: root.Hci, config: Config) !Self {
            return .{
                .central_impl = CentralImpl.init(hci, config.allocator),
                .peripheral_impl = PeripheralImpl.init(hci, config.allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.central_impl.deinit();
            self.peripheral_impl.deinit();
        }

        pub fn central(self: *Self) root.Central {
            return root.Central.wrap(&self.central_impl);
        }

        pub fn peripheral(self: *Self) root.Peripheral {
            return root.Peripheral.wrap(&self.peripheral_impl);
        }
    };

    return make(lib, Impl, Channel);
}
