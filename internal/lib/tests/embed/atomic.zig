const embed = @import("embed");
const testing_mod = @import("testing");

pub fn make(comptime lib: type) testing_mod.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_mod.T, allocator: embed.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.run("load_store_fetch", testing_mod.TestRunner.fromFn(lib, 8 * 1024, struct {
                fn run(tt: *testing_mod.T, sub_allocator: lib.mem.Allocator) !void {
                    _ = tt;
                    _ = sub_allocator;
                    try loadStoreFetchCase(lib);
                }
            }.run));
            t.run("cmpxchg", testing_mod.TestRunner.fromFn(lib, 8 * 1024, struct {
                fn run(tt: *testing_mod.T, sub_allocator: lib.mem.Allocator) !void {
                    _ = tt;
                    _ = sub_allocator;
                    try cmpxchgCase(lib);
                }
            }.run));
            t.run("swap", testing_mod.TestRunner.fromFn(lib, 8 * 1024, struct {
                fn run(tt: *testing_mod.T, sub_allocator: lib.mem.Allocator) !void {
                    _ = tt;
                    _ = sub_allocator;
                    try swapCase(lib);
                }
            }.run));
            t.run("make_uses_custom_atomic", testing_mod.TestRunner.fromFn(lib, 8 * 1024, struct {
                fn run(tt: *testing_mod.T, sub_allocator: lib.mem.Allocator) !void {
                    _ = tt;
                    _ = sub_allocator;
                    try makeUsesCustomAtomicCase(lib);
                }
            }.run));
            return t.wait();
        }

        pub fn deinit(self: *@This(), allocator: embed.mem.Allocator) void {
            _ = allocator;
            lib.testing.allocator.destroy(self);
        }
    };

    const runner = lib.testing.allocator.create(Runner) catch @panic("OOM");
    runner.* = .{};
    return testing_mod.TestRunner.make(Runner).new(runner);
}

fn loadStoreFetchCase(comptime lib: type) !void {
    var v = lib.atomic.Value(u32).init(0);
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

fn cmpxchgCase(comptime lib: type) !void {
    var v = lib.atomic.Value(u32).init(12);
    const swapped = v.cmpxchgStrong(12, 99, .seq_cst, .seq_cst);
    if (swapped != null) return error.CmpxchgShouldSucceed;
    if (v.load(.seq_cst) != 99) return error.CmpxchgValueWrong;

    const failed = v.cmpxchgStrong(0, 1, .seq_cst, .seq_cst);
    if (failed == null) return error.CmpxchgShouldFail;
    if (failed.? != 99) return error.CmpxchgReturnWrong;
}

fn swapCase(comptime lib: type) !void {
    var v = lib.atomic.Value(u32).init(99);
    const old = v.swap(77, .seq_cst);
    if (old != 99) return error.SwapOldWrong;
    if (v.load(.seq_cst) != 77) return error.SwapNewWrong;
}

fn makeUsesCustomAtomicCase(comptime lib: type) !void {
    const AtomicOrder = embed.builtin.AtomicOrder;

    const CustomAtomic = struct {
        pub fn Value(comptime T: type) type {
            return struct {
                pub const marker = true;

                inner: lib.atomic.Value(T),

                pub fn init(value: T) @This() {
                    return .{ .inner = lib.atomic.Value(T).init(value) };
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

    const CustomLib = embed.make(struct {
        pub const Thread = lib.Thread;
        pub const heap = lib.heap;
        pub const log = lib.log;
        pub const testing = lib.testing;
        pub const posix = lib.posix;
        pub const time = lib.time;
        pub const crypto = lib.crypto;
        pub const atomic = CustomAtomic;
    });

    try lib.testing.expect(@hasDecl(CustomLib.atomic.Value(u32), "marker"));

    var value = CustomLib.atomic.Value(u32).init(41);
    try lib.testing.expectEqual(@as(u32, 41), value.load(.seq_cst));
    value.store(42, .seq_cst);
    try lib.testing.expectEqual(@as(u32, 42), value.load(.seq_cst));
}
