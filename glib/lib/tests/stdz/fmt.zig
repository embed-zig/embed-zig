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

            t.run("buf_print", testing_mod.TestRunner.fromFn(std, 12 * 1024, struct {
                fn run(tt: *testing_mod.T, sub_allocator: std.mem.Allocator) !void {
                    _ = tt;
                    _ = sub_allocator;
                    try bufPrintCase(std);
                }
            }.run));
            t.run("alloc_print", testing_mod.TestRunner.fromFn(std, 24 * 1024, struct {
                fn run(tt: *testing_mod.T, sub_allocator: std.mem.Allocator) !void {
                    _ = tt;
                    try allocPrintCase(std, sub_allocator);
                }
            }.run));
            t.run("parse_int", testing_mod.TestRunner.fromFn(std, 12 * 1024, struct {
                fn run(tt: *testing_mod.T, sub_allocator: std.mem.Allocator) !void {
                    _ = tt;
                    _ = sub_allocator;
                    try parseIntCase(std);
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

fn bufPrintCase(comptime std: type) !void {
    var buf: [64]u8 = undefined;
    const formatted = try std.fmt.bufPrint(&buf, "hello {s} #{d}", .{ "stdz", 7 });
    if (!std.mem.eql(u8, formatted, "hello stdz #7")) return error.BufPrintMismatch;
}

fn allocPrintCase(comptime std: type, allocator: std.mem.Allocator) !void {
    const allocated = try std.fmt.allocPrint(allocator, "{s}:{x}", .{ "port", 0xBEEF });
    defer allocator.free(allocated);
    if (!std.mem.eql(u8, allocated, "port:beef")) return error.AllocPrintMismatch;
}

fn parseIntCase(comptime std: type) !void {
    const parsed_dec = try std.fmt.parseInt(u16, "8080", 10);
    const parsed_hex = try std.fmt.parseInt(u16, "ff", 16);
    if (parsed_dec != 8080) return error.ParseIntDecimalFailed;
    if (parsed_hex != 255) return error.ParseIntHexFailed;
}
