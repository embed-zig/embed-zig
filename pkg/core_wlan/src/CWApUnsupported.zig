//! CWApUnsupported — macOS CoreWLAN does not expose public SoftAP support.

const embed = @import("embed");
const drivers = @import("drivers");
const testing_api = @import("testing");
const wifi = drivers.wifi;
const Ap = wifi.Ap;
const Allocator = embed.mem.Allocator;

const CWApUnsupported = @This();

allocator: Allocator,

pub const Config = struct {};

pub fn init(allocator: Allocator, _: Config) CWApUnsupported {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *CWApUnsupported) void {
    const alloc = self.allocator;
    self.* = undefined;
    alloc.destroy(self);
}

pub fn start(self: *CWApUnsupported, _: Ap.Config) Ap.StartError!void {
    _ = self;
    return error.Unsupported;
}

pub fn stop(self: *CWApUnsupported) void {
    _ = self;
}

pub fn disconnectClient(self: *CWApUnsupported, _: Ap.MacAddr) void {
    _ = self;
}

pub fn getState(self: *CWApUnsupported) Ap.State {
    _ = self;
    return .idle;
}

pub fn addEventHook(self: *CWApUnsupported, _: ?*anyopaque, _: *const fn (?*anyopaque, Ap.Event) void) void {
    _ = self;
}

pub fn removeEventHook(self: *CWApUnsupported, _: ?*anyopaque, _: *const fn (?*anyopaque, Ap.Event) void) void {
    _ = self;
}

pub fn getMacAddr(self: *CWApUnsupported) ?Ap.MacAddr {
    _ = self;
    return null;
}

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    const TestCase = struct {
        fn apBackendReportsUnsupported() !void {
            var backend = CWApUnsupported.init(lib.testing.allocator, .{});
            try lib.testing.expectError(error.Unsupported, backend.start(.{
                .ssid = "test-ap",
            }));
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            TestCase.apBackendReportsUnsupported() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: lib.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}
