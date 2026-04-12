const Assembler = @import("../../../../Assembler.zig");
pub const component_wifi = @import("../../../../component/wifi.zig");
const drivers = @import("drivers");

pub const Addr = component_wifi.Addr;
pub const MacAddr = component_wifi.MacAddr;

pub fn makeBuiltApp(comptime lib: type, comptime Channel: fn (type) type) type {
    comptime {
        @setEvalBranchQuota(20_000);
    }
    const AssemblerType = Assembler.make(lib, .{
        .pipeline = .{
            .tick_interval_ns = lib.time.ns_per_ms,
        },
    }, Channel);
    var assembler = AssemblerType.init();
    assembler.addWifiSta(.sta, 31);
    assembler.addWifiAp(.ap, 41);
    assembler.setState("net/wifi/sta", .{.sta});
    assembler.setState("net/wifi/ap", .{.ap});

    const BuildConfig = assembler.BuildConfig();
    const build_config: BuildConfig = .{
        .sta = drivers.wifi.Sta,
        .ap = drivers.wifi.Ap,
    };
    return assembler.build(build_config);
}

pub const DummyStaImpl = struct {
    pub fn startScan(_: *@This(), _: drivers.wifi.Sta.ScanConfig) drivers.wifi.Sta.ScanError!void {}
    pub fn stopScan(_: *@This()) void {}
    pub fn connect(_: *@This(), _: drivers.wifi.Sta.ConnectConfig) drivers.wifi.Sta.ConnectError!void {}
    pub fn disconnect(_: *@This()) void {}
    pub fn getState(_: *@This()) drivers.wifi.Sta.State {
        return .idle;
    }
    pub fn addEventHook(_: *@This(), _: ?*anyopaque, _: *const fn (?*anyopaque, drivers.wifi.Sta.Event) void) void {}
    pub fn deinit(_: *@This()) void {}
};

pub const DummyApImpl = struct {
    pub fn start(_: *@This(), _: drivers.wifi.Ap.Config) drivers.wifi.Ap.StartError!void {}
    pub fn stop(_: *@This()) void {}
    pub fn disconnectClient(_: *@This(), _: drivers.wifi.Ap.MacAddr) void {}
    pub fn getState(_: *@This()) drivers.wifi.Ap.State {
        return .idle;
    }
    pub fn addEventHook(_: *@This(), _: ?*anyopaque, _: *const fn (?*anyopaque, drivers.wifi.Ap.Event) void) void {}
    pub fn deinit(_: *@This()) void {}
};

pub fn macEql(a: MacAddr, b: MacAddr) bool {
    inline for (0..a.len) |i| {
        if (a[i] != b[i]) return false;
    }
    return true;
}

pub fn addrEql(a: Addr, b: Addr) bool {
    return Addr.compare(a, b) == .eq;
}

pub fn optionalAddrEql(a: ?Addr, b: ?Addr) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return addrEql(a.?, b.?);
}
