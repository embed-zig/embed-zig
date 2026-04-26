const binding = @import("binding.zig");
const types = @import("types.zig");

const Self = @This();

index: types.HostApiIndex,
info: *const binding.PaHostApiInfo,

pub fn make(index: types.HostApiIndex, info: *const binding.PaHostApiInfo) Self {
    return .{
        .index = index,
        .info = info,
    };
}

pub fn name(self: Self) [*:0]const u8 {
    return self.info.name;
}

pub fn deviceCount(self: Self) u32 {
    return @intCast(self.info.deviceCount);
}

pub fn defaultInputDevice(self: Self) types.DeviceIndex {
    return self.info.defaultInputDevice;
}

pub fn defaultOutputDevice(self: Self) types.DeviceIndex {
    return self.info.defaultOutputDevice;
}

pub fn TestRunner(comptime lib: type) @import("testing").TestRunner {
    const testing_api = @import("testing");

    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            makesHostApiInfo(lib) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: lib.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }

        fn makesHostApiInfo(comptime L: type) !void {
            const testing = L.testing;

            var info = binding.PaHostApiInfo{
                .structVersion = 1,
                .type = 0,
                .name = "core",
                .deviceCount = 3,
                .defaultInputDevice = 1,
                .defaultOutputDevice = 2,
            };
            const api = make(0, &info);

            try testing.expectEqual(@as(types.HostApiIndex, 0), api.index);
            try testing.expectEqual(@as(u32, 3), api.deviceCount());
            try testing.expectEqual(@as(types.DeviceIndex, 1), api.defaultInputDevice());
            try testing.expectEqual(@as(types.DeviceIndex, 2), api.defaultOutputDevice());
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}
