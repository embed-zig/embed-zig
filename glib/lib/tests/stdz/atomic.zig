const stdz = @import("stdz");
const testing_mod = @import("testing");

pub fn make(comptime std: type) testing_mod.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: stdz.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_mod.T, allocator: stdz.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.run("load_store_fetch", testing_mod.TestRunner.fromFn(std, 8 * 1024, struct {
                fn run(tt: *testing_mod.T, sub_allocator: std.mem.Allocator) !void {
                    _ = tt;
                    _ = sub_allocator;
                    try loadStoreFetchCase(std);
                }
            }.run));
            t.run("cmpxchg", testing_mod.TestRunner.fromFn(std, 8 * 1024, struct {
                fn run(tt: *testing_mod.T, sub_allocator: std.mem.Allocator) !void {
                    _ = tt;
                    _ = sub_allocator;
                    try cmpxchgCase(std);
                }
            }.run));
            t.run("swap", testing_mod.TestRunner.fromFn(std, 8 * 1024, struct {
                fn run(tt: *testing_mod.T, sub_allocator: std.mem.Allocator) !void {
                    _ = tt;
                    _ = sub_allocator;
                    try swapCase(std);
                }
            }.run));
            t.run("make_uses_custom_atomic", testing_mod.TestRunner.fromFn(std, 8 * 1024, struct {
                fn run(tt: *testing_mod.T, sub_allocator: std.mem.Allocator) !void {
                    _ = tt;
                    _ = sub_allocator;
                    try makeUsesCustomAtomicCase(std);
                }
            }.run));
            return t.wait();
        }

        pub fn deinit(self: *@This(), allocator: stdz.mem.Allocator) void {
            _ = allocator;
            std.testing.allocator.destroy(self);
        }
    };

    const runner = std.testing.allocator.create(Runner) catch @panic("OOM");
    runner.* = .{};
    return testing_mod.TestRunner.make(Runner).new(runner);
}

fn loadStoreFetchCase(comptime std: type) !void {
    var v = std.atomic.Value(u32).init(0);
    v.store(10, .seq_cst);
    const loaded = v.load(.seq_cst);
    if (loaded != 10) return error.AtomicStoreFailed;

    const prev = v.fetchAdd(5, .seq_cst);
    if (prev != 10) return error.AtomicFetchAddPrevFailed;
    const after = v.load(.seq_cst);
    if (after != 15) return error.AtomicFetchAddFailed;

    const prev2 = v.fetchSub(3, .seq_cst);
    if (prev2 != 15) return error.AtomicFetchSubPrevFailed;
    const after2 = v.load(.seq_cst);
    if (after2 != 12) return error.AtomicFetchSubFailed;
}

fn cmpxchgCase(comptime std: type) !void {
    var v = std.atomic.Value(u32).init(12);
    const swapped = v.cmpxchgStrong(12, 99, .seq_cst, .seq_cst);
    if (swapped != null) return error.CmpxchgShouldSucceed;
    if (v.load(.seq_cst) != 99) return error.CmpxchgValueWrong;

    const failed = v.cmpxchgStrong(0, 1, .seq_cst, .seq_cst);
    if (failed == null) return error.CmpxchgShouldFail;
    if (failed.? != 99) return error.CmpxchgReturnWrong;
}

fn swapCase(comptime std: type) !void {
    var v = std.atomic.Value(u32).init(99);
    const old = v.swap(77, .seq_cst);
    if (old != 99) return error.SwapOldWrong;
    if (v.load(.seq_cst) != 77) return error.SwapNewWrong;
}

fn makeUsesCustomAtomicCase(comptime std: type) !void {
    const AtomicOrder = stdz.builtin.AtomicOrder;

    const CustomAtomic = struct {
        pub fn Value(comptime T: type) type {
            return struct {
                pub const marker = true;

                inner: std.atomic.Value(T),

                pub fn init(value: T) @This() {
                    return .{ .inner = std.atomic.Value(T).init(value) };
                }

                pub fn load(self: *@This(), comptime order: AtomicOrder) T {
                    return self.inner.load(order);
                }

                pub fn store(self: *@This(), value: T, comptime order: AtomicOrder) void {
                    self.inner.store(value, order);
                }

                pub fn swap(self: *@This(), value: T, comptime order: AtomicOrder) T {
                    return self.inner.swap(value, order);
                }

                pub fn fetchAdd(self: *@This(), operand: T, comptime order: AtomicOrder) T {
                    return self.inner.fetchAdd(operand, order);
                }

                pub fn fetchSub(self: *@This(), operand: T, comptime order: AtomicOrder) T {
                    return self.inner.fetchSub(operand, order);
                }

                pub fn cmpxchgStrong(
                    self: *@This(),
                    expected_value: T,
                    new_value: T,
                    comptime success_order: AtomicOrder,
                    comptime failure_order: AtomicOrder,
                ) ?T {
                    return self.inner.cmpxchgStrong(expected_value, new_value, success_order, failure_order);
                }
            };
        }
    };

    const CustomLib = stdz.make(struct {
        pub const Thread = std.Thread;
        pub const heap = std.heap;
        pub const log = std.log;
        pub const testing = std.testing;
        pub const posix = std.posix;
        pub const time = std.time;
        pub const crypto = std.crypto;
        pub const atomic = CustomAtomic;
    });

    try std.testing.expect(@hasDecl(CustomLib.atomic.Value(u32), "marker"));

    var value = CustomLib.atomic.Value(u32).init(41);
    try std.testing.expectEqual(@as(u32, 41), value.load(.seq_cst));
    value.store(42, .seq_cst);
    try std.testing.expectEqual(@as(u32, 42), value.load(.seq_cst));
}
