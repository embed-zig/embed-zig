//! Semaphore contract — counting semaphore for thread coordination.

const testing_api = @import("testing");

pub fn make(comptime Impl: type) type {
    comptime {
        _ = @as(*const fn (*Impl) void, &Impl.wait);
        _ = @as(*const fn (*Impl, u64) error{Timeout}!void, &Impl.timedWait);
        _ = @as(*const fn (*Impl) void, &Impl.post);
    }

    return struct {
        impl: Impl = .{},

        const Self = @This();

        pub fn wait(self: *Self) void {
            self.impl.wait();
        }

        pub fn timedWait(self: *Self, timeout_ns: u64) error{Timeout}!void {
            return self.impl.timedWait(timeout_ns);
        }

        pub fn post(self: *Self) void {
            self.impl.post();
        }
    };
}

pub fn TestRunner(comptime std: type) testing_api.TestRunner {
    const TestCase = struct {
        fn waitsConsumesAndPostsPermit() !void {
            const Semaphore = make(@import("std").Thread.Semaphore);
            var sem: Semaphore = .{ .impl = .{ .permits = 1 } };

            sem.wait();
            try std.testing.expectEqual(@as(usize, 0), sem.impl.permits);

            sem.post();
            try std.testing.expectEqual(@as(usize, 1), sem.impl.permits);
        }

        fn timedWaitReturnsTimeout() !void {
            const Semaphore = make(@import("std").Thread.Semaphore);
            var sem: Semaphore = .{};

            try std.testing.expectError(error.Timeout, sem.timedWait(1));
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

            TestCase.waitsConsumesAndPostsPermit() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.timedWaitReturnsTimeout() catch |err| {
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
