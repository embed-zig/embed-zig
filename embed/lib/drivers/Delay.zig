//! Delay — non-owning type-erased duration sleep hook.
//!
//! This wrapper is intentionally small for the first `lib/drivers` phase.
//! It forwards `sleep` to an externally owned implementation.

const glib = @import("glib");

const Delay = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    sleep: *const fn (ptr: *anyopaque, duration: glib.time.duration.Duration) void,
};

pub fn sleep(self: Delay, duration: glib.time.duration.Duration) void {
    self.vtable.sleep(self.ptr, duration);
}

pub fn init(pointer: anytype) Delay {
    const Ptr = @TypeOf(pointer);
    const info = @typeInfo(Ptr);
    if (info != .pointer or info.pointer.size != .one)
        @compileError("Delay.init expects a single-item pointer");

    const Impl = info.pointer.child;

    const gen = struct {
        fn sleepFn(ptr: *anyopaque, duration: glib.time.duration.Duration) void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            self.sleep(duration);
        }

        const vtable = VTable{
            .sleep = sleepFn,
        };
    };

    return .{
        .ptr = pointer,
        .vtable = &gen.vtable,
    };
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn dispatchesSleep() !void {
            const Fake = struct {
                calls: usize = 0,
                last_duration: glib.time.duration.Duration = 0,

                fn sleep(self: *@This(), duration: glib.time.duration.Duration) void {
                    self.calls += 1;
                    self.last_duration = duration;
                }
            };

            var fake = Fake{};
            const delay = Delay.init(&fake);

            delay.sleep(10 * glib.time.duration.MilliSecond);
            delay.sleep(25 * glib.time.duration.MilliSecond);

            try grt.std.testing.expectEqual(@as(usize, 2), fake.calls);
            try grt.std.testing.expectEqual(@as(glib.time.duration.Duration, 25 * glib.time.duration.MilliSecond), fake.last_duration);
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            TestCase.dispatchesSleep() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: glib.std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return glib.testing.TestRunner.make(Runner).new(&Holder.runner);
}
