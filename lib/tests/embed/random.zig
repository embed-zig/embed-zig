const TestEnum = enum { zero, one, two, three };
const embed = @import("embed");
const testing_mod = @import("testing");

const ByteSource = struct {
    next: u8 = 1,

    fn fill(self: *ByteSource, buf: []u8) void {
        for (buf) |*b| {
            b.* = self.next;
            self.next +%= 1;
        }
    }
};

pub fn make(comptime lib: type) testing_mod.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_mod.T, allocator: embed.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.run("bytes_and_boolean", testing_mod.TestRunner.fromFn(lib, 24 * 1024, struct {
                fn run(tt: *testing_mod.T, sub_allocator: lib.mem.Allocator) !void {
                    _ = tt;
                    _ = sub_allocator;
                    try bytesAndBooleanTests(lib);
                }
            }.run));
            t.run("enum_and_int", testing_mod.TestRunner.fromFn(lib, 24 * 1024, struct {
                fn run(tt: *testing_mod.T, sub_allocator: lib.mem.Allocator) !void {
                    _ = tt;
                    _ = sub_allocator;
                    try enumAndIntTests(lib);
                }
            }.run));
            t.run("range", testing_mod.TestRunner.fromFn(lib, 32 * 1024, struct {
                fn run(tt: *testing_mod.T, sub_allocator: lib.mem.Allocator) !void {
                    _ = tt;
                    _ = sub_allocator;
                    try rangeTests(lib);
                }
            }.run));
            t.run("float", testing_mod.TestRunner.fromFn(lib, 24 * 1024, struct {
                fn run(tt: *testing_mod.T, sub_allocator: lib.mem.Allocator) !void {
                    _ = tt;
                    _ = sub_allocator;
                    try floatTests(lib);
                }
            }.run));
            t.run("shuffle", testing_mod.TestRunner.fromFn(lib, 24 * 1024, struct {
                fn run(tt: *testing_mod.T, sub_allocator: lib.mem.Allocator) !void {
                    _ = tt;
                    _ = sub_allocator;
                    try shuffleTests(lib);
                }
            }.run));
            t.run("weighted_and_limit", testing_mod.TestRunner.fromFn(lib, 16 * 1024, struct {
                fn run(tt: *testing_mod.T, sub_allocator: lib.mem.Allocator) !void {
                    _ = tt;
                    _ = sub_allocator;
                    try weightedAndLimitTests(lib);
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

fn bytesAndBooleanTests(comptime lib: type) !void {
    var src = ByteSource{};
    var rng = lib.Random.init(&src, ByteSource.fill);

    var bytes: [17]u8 = undefined;
    rng.bytes(&bytes);
    for (bytes, 0..) |b, i| {
        if (b != @as(u8, @intCast(i + 1))) return error.RandomBytesSequenceWrong;
    }

    var next_bytes: [4]u8 = undefined;
    rng.bytes(&next_bytes);
    for (next_bytes, 0..) |b, i| {
        if (b != @as(u8, @intCast(18 + i))) return error.RandomBytesDidNotAdvance;
    }

    var src_a = ByteSource{};
    var src_b = ByteSource{};
    var rng_a = lib.Random.init(&src_a, ByteSource.fill);
    var rng_b = lib.Random.init(&src_b, ByteSource.fill);
    for (0..16) |_| {
        if (rng_a.boolean() != rng_b.boolean()) return error.RandomBooleanDeterminismMismatch;
    }
}

fn enumAndIntTests(comptime lib: type) !void {
    var src_a = ByteSource{};
    var src_b = ByteSource{};
    var rng_a = lib.Random.init(&src_a, ByteSource.fill);
    var rng_b = lib.Random.init(&src_b, ByteSource.fill);

    const enum_value = rng_a.enumValue(TestEnum);
    if (enum_value != rng_b.enumValue(TestEnum)) return error.RandomEnumValueDeterminismMismatch;
    if (@intFromEnum(enum_value) > @intFromEnum(TestEnum.three)) return error.RandomEnumValueOutOfRange;

    const enum_value_indexed = rng_a.enumValueWithIndex(TestEnum, u8);
    if (enum_value_indexed != rng_b.enumValueWithIndex(TestEnum, u8))
        return error.RandomEnumValueWithIndexDeterminismMismatch;
    if (@intFromEnum(enum_value_indexed) > @intFromEnum(TestEnum.three))
        return error.RandomEnumValueWithIndexOutOfRange;

    if (rng_a.int(u32) != rng_b.int(u32)) return error.RandomIntU32DeterminismMismatch;
    if (rng_a.int(i16) != rng_b.int(i16)) return error.RandomIntI16DeterminismMismatch;
}

fn rangeTests(comptime lib: type) !void {
    var src_a = ByteSource{};
    var src_b = ByteSource{};
    var rng_a = lib.Random.init(&src_a, ByteSource.fill);
    var rng_b = lib.Random.init(&src_b, ByteSource.fill);

    const less_than_biased = rng_a.uintLessThanBiased(u16, 1000);
    if (less_than_biased != rng_b.uintLessThanBiased(u16, 1000))
        return error.RandomUintLessThanBiasedDeterminismMismatch;
    if (less_than_biased >= 1000) return error.RandomUintLessThanBiasedOutOfRange;

    const less_than = rng_a.uintLessThan(u16, 1000);
    if (less_than != rng_b.uintLessThan(u16, 1000)) return error.RandomUintLessThanDeterminismMismatch;
    if (less_than >= 1000) return error.RandomUintLessThanOutOfRange;

    const at_most_biased = rng_a.uintAtMostBiased(u16, 1000);
    if (at_most_biased != rng_b.uintAtMostBiased(u16, 1000))
        return error.RandomUintAtMostBiasedDeterminismMismatch;
    if (at_most_biased > 1000) return error.RandomUintAtMostBiasedOutOfRange;

    const at_most = rng_a.uintAtMost(u16, 1000);
    if (at_most != rng_b.uintAtMost(u16, 1000)) return error.RandomUintAtMostDeterminismMismatch;
    if (at_most > 1000) return error.RandomUintAtMostOutOfRange;

    const int_less_than_biased = rng_a.intRangeLessThanBiased(i16, -100, 100);
    if (int_less_than_biased != rng_b.intRangeLessThanBiased(i16, -100, 100))
        return error.RandomIntRangeLessThanBiasedDeterminismMismatch;
    if (int_less_than_biased < -100 or int_less_than_biased >= 100)
        return error.RandomIntRangeLessThanBiasedOutOfRange;

    const int_less_than = rng_a.intRangeLessThan(i16, -100, 100);
    if (int_less_than != rng_b.intRangeLessThan(i16, -100, 100))
        return error.RandomIntRangeLessThanDeterminismMismatch;
    if (int_less_than < -100 or int_less_than >= 100) return error.RandomIntRangeLessThanOutOfRange;

    const int_at_most_biased = rng_a.intRangeAtMostBiased(i16, -100, 100);
    if (int_at_most_biased != rng_b.intRangeAtMostBiased(i16, -100, 100))
        return error.RandomIntRangeAtMostBiasedDeterminismMismatch;
    if (int_at_most_biased < -100 or int_at_most_biased > 100)
        return error.RandomIntRangeAtMostBiasedOutOfRange;

    const int_at_most = rng_a.intRangeAtMost(i16, -100, 100);
    if (int_at_most != rng_b.intRangeAtMost(i16, -100, 100))
        return error.RandomIntRangeAtMostDeterminismMismatch;
    if (int_at_most < -100 or int_at_most > 100) return error.RandomIntRangeAtMostOutOfRange;
}

fn floatTests(comptime lib: type) !void {
    var src_a = ByteSource{};
    var src_b = ByteSource{};
    var rng_a = lib.Random.init(&src_a, ByteSource.fill);
    var rng_b = lib.Random.init(&src_b, ByteSource.fill);

    const f32_value = rng_a.float(f32);
    if (@as(u32, @bitCast(f32_value)) != @as(u32, @bitCast(rng_b.float(f32))))
        return error.RandomFloatF32DeterminismMismatch;
    if (!isFiniteFloat(f32_value) or f32_value < 0 or f32_value >= 1)
        return error.RandomFloatF32OutOfRange;

    const f64_value = rng_a.float(f64);
    if (@as(u64, @bitCast(f64_value)) != @as(u64, @bitCast(rng_b.float(f64))))
        return error.RandomFloatF64DeterminismMismatch;
    if (!isFiniteFloat(f64_value) or f64_value < 0 or f64_value >= 1)
        return error.RandomFloatF64OutOfRange;

    const norm_value = rng_a.floatNorm(f64);
    if (@as(u64, @bitCast(norm_value)) != @as(u64, @bitCast(rng_b.floatNorm(f64))))
        return error.RandomFloatNormDeterminismMismatch;
    if (!isFiniteFloat(norm_value)) return error.RandomFloatNormNotFinite;

    const exp_value = rng_a.floatExp(f64);
    if (@as(u64, @bitCast(exp_value)) != @as(u64, @bitCast(rng_b.floatExp(f64))))
        return error.RandomFloatExpDeterminismMismatch;
    if (!isFiniteFloat(exp_value) or exp_value < 0) return error.RandomFloatExpOutOfRange;
}

fn shuffleTests(comptime lib: type) !void {
    {
        var src_a = ByteSource{};
        var src_b = ByteSource{};
        var rng_a = lib.Random.init(&src_a, ByteSource.fill);
        var rng_b = lib.Random.init(&src_b, ByteSource.fill);

        const original = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7 };
        var buf_a = original;
        var buf_b = original;
        rng_a.shuffle(u8, &buf_a);
        rng_b.shuffle(u8, &buf_b);

        if (!lib.mem.eql(u8, &buf_a, &buf_b)) return error.RandomShuffleDeterminismMismatch;
        if (!isPermutation(&original, &buf_a)) return error.RandomShufflePermutationMismatch;
    }

    {
        var src_a = ByteSource{};
        var src_b = ByteSource{};
        var rng_a = lib.Random.init(&src_a, ByteSource.fill);
        var rng_b = lib.Random.init(&src_b, ByteSource.fill);

        const original = [_]u8{ 10, 11, 12, 13, 14, 15, 16, 17 };
        var buf_a = original;
        var buf_b = original;
        rng_a.shuffleWithIndex(u8, &buf_a, u8);
        rng_b.shuffleWithIndex(u8, &buf_b, u8);

        if (!lib.mem.eql(u8, &buf_a, &buf_b)) return error.RandomShuffleWithIndexDeterminismMismatch;
        if (!isPermutation(&original, &buf_a)) return error.RandomShuffleWithIndexPermutationMismatch;
    }
}

fn weightedAndLimitTests(comptime lib: type) !void {
    var src_a = ByteSource{};
    var src_b = ByteSource{};
    var rng_a = lib.Random.init(&src_a, ByteSource.fill);
    var rng_b = lib.Random.init(&src_b, ByteSource.fill);

    const proportions = [_]u8{ 1, 3, 7, 9 };
    const index = rng_a.weightedIndex(u8, &proportions);
    if (index != rng_b.weightedIndex(u8, &proportions)) return error.RandomWeightedIndexDeterminismMismatch;
    if (index >= proportions.len) return error.RandomWeightedIndexOutOfRange;

    const limited = lib.Random.limitRangeBiased(u16, 0xBEEF, 10);
    if (limited >= 10) return error.RandomLimitRangeBiasedOutOfRange;
}

fn isPermutation(original: []const u8, shuffled: []const u8) bool {
    if (original.len != shuffled.len) return false;
    for (original) |wanted| {
        var count: usize = 0;
        for (shuffled) |got| {
            if (got == wanted) count += 1;
        }
        if (count != 1) return false;
    }
    return true;
}

fn isFiniteFloat(value: anytype) bool {
    return value == value and (value - value) == (value - value);
}
