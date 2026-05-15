//! Arc — atomically reference-counted ownership for heap-allocated values.
//!
//! `Arc.make(std, T)` builds an owning control block around an
//! already-initialized `*T`. `adopt` takes ownership of that pointer and returns
//! a control-block pointer. `clone` creates another owning reference, and the
//! final `deinit` calls `T.deinit()` before destroying the adopted value with the
//! allocator passed to `adopt`.
//!
//! Copying the returned pointer does not increment the reference count. Every
//! independently released reference must come from `adopt` or `clone`.

const testing_api = @import("testing");

pub fn make(comptime std: type, comptime T: type) type {
    const Allocator = std.mem.Allocator;
    const AtomicUsize = std.atomic.Value(usize);

    comptime {
        _ = @as(*const fn (*T) void, &T.deinit);
    }

    return struct {
        allocator: Allocator,
        value: Ptr,
        refs: AtomicUsize = AtomicUsize.init(1),

        const Self = @This();
        pub const Arc = *Self;
        pub const Ptr = *T;

        /// Takes ownership of `value`.
        ///
        /// `value` must have been allocated with `allocator.create(T)`. After a
        /// successful `adopt`, callers must not call `value.deinit()` or
        /// `allocator.destroy(value)` directly.
        ///
        /// The returned pointer owns one reference. Call `clone` for each
        /// additional owner.
        pub fn adopt(allocator: Allocator, value: Ptr) !Arc {
            const arc = try allocator.create(Self);
            arc.* = .{
                .allocator = allocator,
                .value = value,
            };
            return arc;
        }

        pub fn clone(self: Arc) Arc {
            _ = self.refs.fetchAdd(1, .acq_rel);
            return self;
        }

        pub fn ptr(self: Arc) Ptr {
            return self.value;
        }

        pub fn deinit(self: Arc) void {
            const previous = self.refs.fetchSub(1, .acq_rel);
            if (previous != 1) return;

            self.value.deinit();
            const allocator = self.allocator;
            allocator.destroy(self.value);
            allocator.destroy(self);
        }
    };
}

pub fn TestRunner(comptime std: type) testing_api.TestRunner {
    const TestCase = struct {
        fn cloneKeepsValueAlive() !void {
            const Counters = struct {
                deinit_count: usize = 0,
            };
            const Item = struct {
                counters: *Counters,
                value: usize,

                pub fn deinit(self: *@This()) void {
                    self.counters.deinit_count += 1;
                }
            };

            var counters = Counters{};
            const item = try std.testing.allocator.create(Item);
            item.* = .{
                .counters = &counters,
                .value = 7,
            };

            const ItemArc = make(std, Item);
            const arc = try ItemArc.adopt(std.testing.allocator, item);
            const cloned = arc.clone();

            arc.deinit();
            try std.testing.expectEqual(@as(usize, 0), counters.deinit_count);
            try std.testing.expect(cloned.ptr() == item);
            try std.testing.expectEqual(@as(usize, 7), cloned.ptr().value);

            cloned.ptr().value = 9;
            cloned.deinit();
            try std.testing.expectEqual(@as(usize, 1), counters.deinit_count);
        }

        fn finalReleaseDestroysValue() !void {
            const Counters = struct {
                deinit_count: usize = 0,
            };
            const Item = struct {
                counters: *Counters,

                pub fn deinit(self: *@This()) void {
                    self.counters.deinit_count += 1;
                }
            };

            var counters = Counters{};
            const item = try std.testing.allocator.create(Item);
            item.* = .{ .counters = &counters };

            const ItemArc = make(std, Item);
            const arc = try ItemArc.adopt(std.testing.allocator, item);

            try std.testing.expect(arc.ptr() == item);
            arc.deinit();
            try std.testing.expectEqual(@as(usize, 1), counters.deinit_count);
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

            TestCase.cloneKeepsValueAlive() catch |err| {
                t.logErrorf("sync.Arc clone lifetime failed: {}", .{err});
                return false;
            };
            TestCase.finalReleaseDestroysValue() catch |err| {
                t.logErrorf("sync.Arc final release failed: {}", .{err});
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
