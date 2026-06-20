//! RwLock contract — reader-writer lock.

const testing_api = @import("testing");

pub fn make(comptime Impl: type) type {
    comptime {
        _ = @as(*const fn (*Impl) void, &Impl.lockShared);
        _ = @as(*const fn (*Impl) void, &Impl.unlockShared);
        _ = @as(*const fn (*Impl) void, &Impl.lock);
        _ = @as(*const fn (*Impl) void, &Impl.unlock);
        _ = @as(*const fn (*Impl) bool, &Impl.tryLockShared);
        _ = @as(*const fn (*Impl) bool, &Impl.tryLock);
    }

    return struct {
        impl: Impl = .{},

        const Self = @This();

        pub fn lockShared(self: *Self) void {
            self.impl.lockShared();
        }

        pub fn unlockShared(self: *Self) void {
            self.impl.unlockShared();
        }

        pub fn lock(self: *Self) void {
            self.impl.lock();
        }

        pub fn unlock(self: *Self) void {
            self.impl.unlock();
        }

        pub fn tryLockShared(self: *Self) bool {
            return self.impl.tryLockShared();
        }

        pub fn tryLock(self: *Self) bool {
            return self.impl.tryLock();
        }
    };
}

pub fn TestRunner(comptime std: type) testing_api.TestRunner {
    const native_std = @import("std");

    const TestCase = struct {
        fn locksSharedAndExclusive() !void {
            const RwLock = make(native_std.Thread.RwLock);
            var rwlock: RwLock = .{};

            try std.testing.expect(rwlock.tryLockShared());
            rwlock.unlockShared();

            try std.testing.expect(rwlock.tryLock());
            rwlock.unlock();

            rwlock.lockShared();
            rwlock.unlockShared();

            rwlock.lock();
            rwlock.unlock();
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

            TestCase.locksSharedAndExclusive() catch |err| {
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
