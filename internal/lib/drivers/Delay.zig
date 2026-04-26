//! Delay — non-owning type-erased millisecond sleep hook.
//!
//! This wrapper is intentionally small for the first `lib/drivers` phase.
//! It forwards `sleepMs` to an externally owned implementation.

const glib = @import("glib");

const Delay = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    sleepMs: *const fn (ptr: *anyopaque, ms: u32) void,
};

pub fn sleepMs(self: Delay, ms: u32) void {
    self.vtable.sleepMs(self.ptr, ms);
}

pub fn init(pointer: anytype) Delay {
    const Ptr = @TypeOf(pointer);
    const info = @typeInfo(Ptr);
    if (info != .pointer or info.pointer.size != .one)
        @compileError("Delay.init expects a single-item pointer");

    const Impl = info.pointer.child;

    const gen = struct {
        fn sleepMsFn(ptr: *anyopaque, ms: u32) void {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            self.sleepMs(ms);
        }

        const vtable = VTable{
            .sleepMs = sleepMsFn,
        };
    };

    return .{
        .ptr = pointer,
        .vtable = &gen.vtable,
    };
}

pub fn TestRunner(comptime lib: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn dispatchesSleepMs() !void {
            const Fake = struct {
                calls: usize = 0,
                last_ms: u32 = 0,

                fn sleepMs(self: *@This(), ms: u32) void {
                    self.calls += 1;
                    self.last_ms = ms;
                }
            };

            var fake = Fake{};
            const delay = Delay.init(&fake);

            delay.sleepMs(10);
            delay.sleepMs(25);

            try lib.testing.expectEqual(@as(usize, 2), fake.calls);
            try lib.testing.expectEqual(@as(u32, 25), fake.last_ms);
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            TestCase.dispatchesSleepMs() catch |err| {
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
    return glib.testing.TestRunner.make(Runner).new(&Holder.runner);
}
