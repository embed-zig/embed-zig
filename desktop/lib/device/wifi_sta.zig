const builtin = @import("builtin");
const embed = @import("embed");
const glib = @import("glib");

pub const WifiSta = @This();
const Sta = embed.drivers.wifi.Sta;
const Impl = switch (builtin.target.os.tag) {
    .macos => @import("wifi_sta_darwin.zig"),
    else => Unsupported,
};

pub const Config = Impl.Config;

inner: Impl,
last_connect_error: ?[]const u8 = null,

pub fn init(allocator: glib.std.mem.Allocator, config: Config) !WifiSta {
    return .{
        .inner = try Impl.init(allocator, config),
        .last_connect_error = null,
    };
}

pub fn deinit(self: *WifiSta) void {
    self.inner.deinit();
    self.* = undefined;
}

pub fn handle(self: *WifiSta) Sta {
    return Sta.make(self);
}

pub fn startScan(self: *WifiSta, config: Sta.ScanConfig) Sta.ScanError!void {
    return self.inner.startScan(config);
}

pub fn stopScan(self: *WifiSta) void {
    self.inner.stopScan();
}

pub fn connect(self: *WifiSta, config: Sta.ConnectConfig) Sta.ConnectError!void {
    self.inner.connect(config) catch |err| {
        self.last_connect_error = @errorName(err);
        return err;
    };
    self.last_connect_error = null;
}

pub fn disconnect(self: *WifiSta) void {
    self.inner.disconnect();
}

pub fn getState(self: *WifiSta) Sta.State {
    return self.inner.getState();
}

pub fn addEventHook(
    self: *WifiSta,
    ctx: ?*anyopaque,
    cb: *const fn (?*anyopaque, Sta.Event) void,
) void {
    self.inner.addEventHook(ctx, cb);
}

pub fn removeEventHook(
    self: *WifiSta,
    ctx: ?*anyopaque,
    cb: *const fn (?*anyopaque, Sta.Event) void,
) void {
    self.inner.removeEventHook(ctx, cb);
}

pub fn getMacAddr(self: *WifiSta) ?Sta.MacAddr {
    return self.inner.getMacAddr();
}

pub fn getIpInfo(self: *WifiSta) ?Sta.IpInfo {
    return self.inner.getIpInfo();
}

pub fn getCurrentSsid(self: *WifiSta, out: *[Sta.max_ssid_len]u8) ?[]const u8 {
    if (@hasDecl(Impl, "getCurrentSsid")) {
        return self.inner.getCurrentSsid(out);
    }
    return null;
}

pub fn getLastConnectError(self: *WifiSta) ?[]const u8 {
    return self.last_connect_error;
}

const Unsupported = struct {
    pub const Config = struct {};

    pub fn init(allocator: glib.std.mem.Allocator, config: @This().Config) !@This() {
        _ = allocator;
        _ = config;
        return .{};
    }

    pub fn deinit(self: *@This()) void {
        self.* = undefined;
    }

    pub fn startScan(self: *@This(), config: Sta.ScanConfig) Sta.ScanError!void {
        _ = self;
        _ = config;
        return error.Unexpected;
    }

    pub fn stopScan(self: *@This()) void {
        _ = self;
    }

    pub fn connect(self: *@This(), config: Sta.ConnectConfig) Sta.ConnectError!void {
        _ = self;
        _ = config;
        return error.Unexpected;
    }

    pub fn disconnect(self: *@This()) void {
        _ = self;
    }

    pub fn getState(self: *@This()) Sta.State {
        _ = self;
        return .idle;
    }

    pub fn addEventHook(
        self: *@This(),
        ctx: ?*anyopaque,
        cb: *const fn (?*anyopaque, Sta.Event) void,
    ) void {
        _ = self;
        _ = ctx;
        _ = cb;
    }

    pub fn removeEventHook(
        self: *@This(),
        ctx: ?*anyopaque,
        cb: *const fn (?*anyopaque, Sta.Event) void,
    ) void {
        _ = self;
        _ = ctx;
        _ = cb;
    }

    pub fn getMacAddr(self: *@This()) ?Sta.MacAddr {
        _ = self;
        return null;
    }

    pub fn getIpInfo(self: *@This()) ?Sta.IpInfo {
        _ = self;
        return null;
    }
};

pub fn TestRunner(comptime std: type) glib.testing.TestRunner {
    const testing_api = glib.testing;

    const TestCase = struct {
        fn wifiStaHandleExposesDriverContract() !void {
            var sta = try WifiSta.init(std.testing.allocator, .{});
            defer sta.deinit();

            const sta_handle = sta.handle();
            try std.testing.expectEqual(Sta.State.idle, sta_handle.getState());
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

            TestCase.wifiStaHandleExposesDriverContract() catch |err| {
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
