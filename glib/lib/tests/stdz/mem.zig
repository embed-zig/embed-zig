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

            t.run("endian_roundtrip", testing_mod.TestRunner.fromFn(std, 8 * 1024, struct {
                fn run(tt: *testing_mod.T, sub_allocator: std.mem.Allocator) !void {
                    _ = tt;
                    _ = sub_allocator;
                    try endianRoundtripCase(std);
                }
            }.run));
            t.run("read_write_int", testing_mod.TestRunner.fromFn(std, 8 * 1024, struct {
                fn run(tt: *testing_mod.T, sub_allocator: std.mem.Allocator) !void {
                    _ = tt;
                    _ = sub_allocator;
                    try readWriteIntCase(std);
                }
            }.run));
            t.run("eql_index_scalar", testing_mod.TestRunner.fromFn(std, 12 * 1024, struct {
                fn run(tt: *testing_mod.T, sub_allocator: std.mem.Allocator) !void {
                    _ = tt;
                    _ = sub_allocator;
                    try eqlIndexScalarCase(std);
                }
            }.run));
            t.run("trim", testing_mod.TestRunner.fromFn(std, 8 * 1024, struct {
                fn run(tt: *testing_mod.T, sub_allocator: std.mem.Allocator) !void {
                    _ = tt;
                    _ = sub_allocator;
                    try trimCase(std);
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

fn endianRoundtripCase(comptime std: type) !void {
    _ = std.mem.Allocator;

    const val: u16 = 0x1234;
    const big = std.mem.nativeToBig(u16, val);
    const back = std.mem.bigToNative(u16, big);
    if (back != val) return error.EndianRoundtripFailed;

    const val32: u32 = 0xDEADBEEF;
    const big32 = std.mem.nativeToBig(u32, val32);
    const back32 = std.mem.bigToNative(u32, big32);
    if (back32 != val32) return error.Endian32RoundtripFailed;
}

fn readWriteIntCase(comptime std: type) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, 0x12345678, .big);
    const got_be = std.mem.readInt(u32, &bytes, .big);
    const got_le = std.mem.readInt(u32, &bytes, .little);
    if (got_be != 0x12345678) return error.ReadWriteIntBigEndianFailed;
    if (got_le != 0x78563412) return error.ReadWriteIntLittleEndianMismatch;
}

fn eqlIndexScalarCase(comptime std: type) !void {
    if (!std.mem.eql(u8, "stdz", "stdz")) return error.MemEqlEqualFailed;
    if (std.mem.eql(u8, "stdz", "std")) return error.MemEqlDifferentFailed;

    const needle = std.mem.indexOf(u8, "hello stdz world", "stdz") orelse return error.IndexOfFailed;
    if (needle != 6) return error.IndexOfWrongOffset;

    if (std.mem.indexOf(u8, "hello stdz world", "zig") != null) return error.IndexOfUnexpectedMatch;

    const first_colon = std.mem.indexOfScalar(u8, "a:b:c", ':') orelse return error.IndexOfScalarFailed;
    const last_colon = std.mem.lastIndexOfScalar(u8, "a:b:c", ':') orelse return error.LastIndexOfScalarFailed;
    if (first_colon != 1) return error.IndexOfScalarWrongOffset;
    if (last_colon != 3) return error.LastIndexOfScalarWrongOffset;
}

fn trimCase(comptime std: type) !void {
    const trimmed = std.mem.trim(u8, " \t  hello stdz \n", &std.ascii.whitespace);
    if (!std.mem.eql(u8, trimmed, "hello stdz")) return error.TrimFailed;
}
