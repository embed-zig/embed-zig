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
            runImpl(lib, allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
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

fn runImpl(comptime lib: type, allocator: lib.mem.Allocator) !void {
    {
        var buf: [64]u8 = undefined;
        const formatted = try lib.fmt.bufPrint(&buf, "hello {s} #{d}", .{ "embed", 7 });
        if (!lib.mem.eql(u8, formatted, "hello embed #7")) return error.BufPrintMismatch;
    }

    {
        const allocated = try lib.fmt.allocPrint(allocator, "{s}:{x}", .{ "port", 0xBEEF });
        defer allocator.free(allocated);
        if (!lib.mem.eql(u8, allocated, "port:beef")) return error.AllocPrintMismatch;
    }

    {
        const parsed_dec = try lib.fmt.parseInt(u16, "8080", 10);
        const parsed_hex = try lib.fmt.parseInt(u16, "ff", 16);
        if (parsed_dec != 8080) return error.ParseIntDecimalFailed;
        if (parsed_hex != 255) return error.ParseIntHexFailed;
    }
}
