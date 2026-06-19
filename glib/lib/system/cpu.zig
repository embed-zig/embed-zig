//! CPU information contract.

pub const CpuCountError = error{
    PermissionDenied,
    SystemResources,
    Unsupported,
    Unexpected,
};

pub fn make(comptime Impl: type) type {
    comptime {
        _ = @as(*const fn () CpuCountError!usize, &Impl.cpuCount);
    }

    return struct {
        pub const CpuCountError = cpu.CpuCountError;

        pub fn cpuCount() cpu.CpuCountError!usize {
            const count = try Impl.cpuCount();
            if (count == 0) return error.Unsupported;
            return count;
        }
    };
}

const cpu = @This();

pub fn TestRunner(comptime std: type) @import("testing").TestRunner {
    const testing_api = @import("testing");

    const TestCase = struct {
        const SuccessImpl = struct {
            pub fn cpuCount() CpuCountError!usize {
                return 2;
            }
        };

        const ZeroImpl = struct {
            pub fn cpuCount() CpuCountError!usize {
                return 0;
            }
        };

        const UnsupportedImpl = struct {
            pub fn cpuCount() CpuCountError!usize {
                return error.Unsupported;
            }
        };

        fn returnsPositiveCpuCount() !void {
            const SystemCpu = make(SuccessImpl);
            try std.testing.expectEqual(@as(usize, 2), try SystemCpu.cpuCount());
        }

        fn rejectsZeroCpuCount() !void {
            const SystemCpu = make(ZeroImpl);
            try std.testing.expectError(error.Unsupported, SystemCpu.cpuCount());
        }

        fn forwardsBackendErrors() !void {
            const SystemCpu = make(UnsupportedImpl);
            try std.testing.expectError(error.Unsupported, SystemCpu.cpuCount());
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

            TestCase.returnsPositiveCpuCount() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.rejectsZeroCpuCount() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.forwardsBackendErrors() catch |err| {
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
