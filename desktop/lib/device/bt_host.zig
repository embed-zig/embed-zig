const builtin = @import("builtin");
const embed = @import("embed");
const glib = @import("glib");

pub const BtHost = @This();
const Impl = switch (builtin.target.os.tag) {
    .macos => @import("bt_host_darwin.zig"),
    else => Unsupported,
};

pub const Config = Impl.Config;

inner: Impl,

pub fn init(allocator: glib.std.mem.Allocator, config: Config) !BtHost {
    return .{
        .inner = try Impl.init(allocator, config),
    };
}

pub fn deinit(self: *BtHost) void {
    self.inner.deinit();
    self.* = undefined;
}

pub fn handle(self: *BtHost) embed.bt.Host {
    return self.inner.handle();
}

const Unsupported = struct {
    pub const Config = struct {
        allocator: glib.std.mem.Allocator = undefined,
        source_id: u32 = 0,
    };

    host: embed.bt.Host,

    pub fn init(allocator: glib.std.mem.Allocator, config: @This().Config) !@This() {
        _ = config;
        const storage = try allocator.create(UnsupportedImpl);
        storage.* = .{ .allocator = allocator };
        return .{
            .host = .{
                .ptr = storage,
                .vtable = &UnsupportedImpl.vtable,
            },
        };
    }

    pub fn deinit(self: *@This()) void {
        self.host.deinit();
        self.* = undefined;
    }

    pub fn handle(self: *@This()) embed.bt.Host {
        return self.host;
    }
};

const UnsupportedImpl = struct {
    allocator: glib.std.mem.Allocator,

    fn deinitFn(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const allocator = self.allocator;
        self.* = undefined;
        allocator.destroy(self);
    }

    fn centralFn(_: *anyopaque) embed.bt.Central {
        return embed.bt.Central.make(&unsupported_central);
    }

    fn peripheralFn(_: *anyopaque) embed.bt.Peripheral {
        return embed.bt.Peripheral.make(&unsupported_peripheral);
    }

    fn setEventCallbackFn(_: *anyopaque, _: *const anyopaque, _: embed.bt.Host.CallbackFn) void {}

    fn clearEventCallbackFn(_: *anyopaque) void {}

    const vtable = embed.bt.Host.VTable{
        .deinit = deinitFn,
        .central = centralFn,
        .peripheral = peripheralFn,
        .setEventCallback = setEventCallbackFn,
        .clearEventCallback = clearEventCallbackFn,
    };
};

var unsupported_central = UnsupportedCentral{};
var unsupported_peripheral = UnsupportedPeripheral{};

const UnsupportedCentral = struct {
    pub fn deinit(_: *@This()) void {}

    pub fn start(_: *@This()) embed.bt.Central.StartError!void {
        return error.BluetoothUnavailable;
    }

    pub fn stop(_: *@This()) void {}

    pub fn startScanning(_: *@This(), _: embed.bt.Central.ScanConfig) embed.bt.Central.ScanError!void {
        return error.Unexpected;
    }

    pub fn stopScanning(_: *@This()) void {}

    pub fn connect(
        _: *@This(),
        _: embed.bt.Central.BdAddr,
        _: embed.bt.Central.AddrType,
        _: embed.bt.Central.ConnParams,
    ) embed.bt.Central.ConnectError!embed.bt.Central.ConnectionInfo {
        return error.Unexpected;
    }

    pub fn disconnect(_: *@This(), _: u16) void {}

    pub fn discoverServices(_: *@This(), _: u16, _: []embed.bt.Central.DiscoveredService) embed.bt.Central.GattError!usize {
        return error.Disconnected;
    }

    pub fn discoverChars(_: *@This(), _: u16, _: u16, _: u16, _: []embed.bt.Central.DiscoveredChar) embed.bt.Central.GattError!usize {
        return error.Disconnected;
    }

    pub fn gattRead(_: *@This(), _: u16, _: u16, _: []u8) embed.bt.Central.GattError!usize {
        return error.Disconnected;
    }

    pub fn gattWrite(_: *@This(), _: u16, _: u16, _: []const u8) embed.bt.Central.GattError!void {
        return error.Disconnected;
    }

    pub fn gattWriteNoResp(_: *@This(), _: u16, _: u16, _: []const u8) embed.bt.Central.GattError!void {
        return error.Disconnected;
    }

    pub fn exchangeMtu(_: *@This(), _: u16, _: u16) embed.bt.Central.GattError!u16 {
        return error.Disconnected;
    }

    pub fn subscribe(_: *@This(), _: u16, _: u16) embed.bt.Central.GattError!void {
        return error.Disconnected;
    }

    pub fn subscribeIndications(_: *@This(), _: u16, _: u16) embed.bt.Central.GattError!void {
        return error.Disconnected;
    }

    pub fn unsubscribe(_: *@This(), _: u16, _: u16) embed.bt.Central.GattError!void {
        return error.Disconnected;
    }

    pub fn getAttMtu(_: *@This(), _: u16) u16 {
        return embed.bt.Central.DEFAULT_ATT_MTU;
    }

    pub fn getState(_: *@This()) embed.bt.Central.State {
        return .idle;
    }

    pub fn getAddr(_: *@This()) ?embed.bt.Central.BdAddr {
        return null;
    }

    pub fn addEventHook(_: *@This(), _: ?*anyopaque, _: *const fn (?*anyopaque, embed.bt.Central.Event) void) void {}

    pub fn removeEventHook(_: *@This(), _: ?*anyopaque, _: *const fn (?*anyopaque, embed.bt.Central.Event) void) void {}
};

const UnsupportedPeripheral = struct {
    pub fn deinit(_: *@This()) void {}

    pub fn start(_: *@This()) embed.bt.Peripheral.StartError!void {
        return error.BluetoothUnavailable;
    }

    pub fn stop(_: *@This()) void {}

    pub fn startAdvertising(_: *@This(), _: embed.bt.Peripheral.AdvConfig) embed.bt.Peripheral.AdvError!void {
        return error.Unexpected;
    }

    pub fn stopAdvertising(_: *@This()) void {}

    pub fn setConfig(_: *@This(), _: embed.bt.Peripheral.GattConfig) void {}

    pub fn setRequestHandler(_: *@This(), _: ?*anyopaque, _: embed.bt.Peripheral.RequestHandlerFn) void {}

    pub fn notify(_: *@This(), _: u16, _: u16, _: []const u8) embed.bt.Peripheral.GattError!void {
        return error.NotConnected;
    }

    pub fn indicate(_: *@This(), _: u16, _: u16, _: []const u8) embed.bt.Peripheral.GattError!void {
        return error.NotConnected;
    }

    pub fn disconnect(_: *@This(), _: u16) void {}

    pub fn getState(_: *@This()) embed.bt.Peripheral.State {
        return .idle;
    }

    pub fn getAddr(_: *@This()) ?embed.bt.Peripheral.BdAddr {
        return null;
    }

    pub fn addEventHook(_: *@This(), _: ?*anyopaque, _: *const fn (?*anyopaque, embed.bt.Peripheral.Event) void) void {}

    pub fn removeEventHook(_: *@This(), _: ?*anyopaque, _: *const fn (?*anyopaque, embed.bt.Peripheral.Event) void) void {}

    pub fn addSubscriptionHook(_: *@This(), _: ?*anyopaque, _: *const fn (?*anyopaque, embed.bt.Peripheral.SubscriptionInfo) void) void {}

    pub fn removeSubscriptionHook(_: *@This(), _: ?*anyopaque, _: *const fn (?*anyopaque, embed.bt.Peripheral.SubscriptionInfo) void) void {}
};

pub fn TestRunner(comptime std: type) glib.testing.TestRunner {
    const testing_api = glib.testing;

    const TestCase = struct {
        fn hostHandleExposesCentralAndPeripheral() !void {
            var host = try BtHost.init(std.testing.allocator, .{ .allocator = std.testing.allocator });
            defer host.deinit();

            _ = host.handle().central();
            _ = host.handle().peripheral();
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            TestCase.hostHandleExposesCentralAndPeripheral() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}
