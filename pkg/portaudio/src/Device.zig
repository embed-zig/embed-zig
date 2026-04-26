const binding = @import("binding.zig");
const types = @import("types.zig");

const Self = @This();

index: types.DeviceIndex,
info: *const binding.PaDeviceInfo,

pub fn make(index: types.DeviceIndex, info: *const binding.PaDeviceInfo) Self {
    return .{
        .index = index,
        .info = info,
    };
}

pub fn name(self: Self) [*:0]const u8 {
    return self.info.name;
}

pub fn hostApiIndex(self: Self) types.HostApiIndex {
    return self.info.hostApi;
}

pub fn maxInputChannels(self: Self) u32 {
    return @intCast(self.info.maxInputChannels);
}

pub fn maxOutputChannels(self: Self) u32 {
    return @intCast(self.info.maxOutputChannels);
}

pub fn defaultLowInputLatency(self: Self) types.Time {
    return self.info.defaultLowInputLatency;
}

pub fn defaultLowOutputLatency(self: Self) types.Time {
    return self.info.defaultLowOutputLatency;
}

pub fn defaultHighInputLatency(self: Self) types.Time {
    return self.info.defaultHighInputLatency;
}

pub fn defaultHighOutputLatency(self: Self) types.Time {
    return self.info.defaultHighOutputLatency;
}

pub fn defaultSampleRate(self: Self) f64 {
    return self.info.defaultSampleRate;
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

            makesDeviceInfo(lib) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: lib.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }

        fn makesDeviceInfo(comptime L: type) !void {
            const testing = L.testing;

            var info = binding.PaDeviceInfo{
                .structVersion = 2,
                .name = "built-in",
                .hostApi = 1,
                .maxInputChannels = 2,
                .maxOutputChannels = 4,
                .defaultLowInputLatency = 0.01,
                .defaultLowOutputLatency = 0.02,
                .defaultHighInputLatency = 0.11,
                .defaultHighOutputLatency = 0.12,
                .defaultSampleRate = 48_000,
            };
            const device = make(7, &info);

            try testing.expectEqual(@as(types.DeviceIndex, 7), device.index);
            try testing.expectEqual(@as(u32, 2), device.maxInputChannels());
            try testing.expectEqual(@as(u32, 4), device.maxOutputChannels());
            try testing.expectEqual(@as(f64, 48_000), device.defaultSampleRate());
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}
