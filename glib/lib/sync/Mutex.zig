//! Mutex contract — mutual exclusion lock.

pub fn make(comptime Impl: type) type {
    comptime {
        _ = @as(*const fn (*Impl) void, &Impl.lock);
        _ = @as(*const fn (*Impl) void, &Impl.unlock);
        _ = @as(*const fn (*Impl) bool, &Impl.tryLock);
    }

    return struct {
        impl: Impl = .{},

        const Self = @This();

        pub fn lock(self: *Self) void {
            self.impl.lock();
        }

        pub fn unlock(self: *Self) void {
            self.impl.unlock();
        }

        pub fn tryLock(self: *Self) bool {
            return self.impl.tryLock();
        }
    };
}

pub fn TestRunner(comptime std: type) @import("testing").TestRunner {
    const testing_api = @import("testing");

    const TestCase = struct {
        fn locksUnlocksAndTryLocks() !void {
            const Mutex = make(std.Thread.Mutex);
            var mutex: Mutex = .{};

            try std.testing.expect(mutex.tryLock());
            mutex.unlock();

            mutex.lock();
            mutex.unlock();
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

            TestCase.locksUnlocksAndTryLocks() catch |err| {
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
