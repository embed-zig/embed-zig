const stdz = @import("stdz");
const host_std = @import("std");
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

            t.run("arena_allocator_type_identity", testing_mod.TestRunner.fromFn(std, 8 * 1024, struct {
                fn run(tt: *testing_mod.T, sub_allocator: std.mem.Allocator) !void {
                    _ = tt;
                    _ = sub_allocator;
                    try arenaAllocatorTypeIdentityCase(std);
                }
            }.run));
            t.run("arena_allocator_allocates", testing_mod.TestRunner.fromFn(std, 16 * 1024, struct {
                fn run(tt: *testing_mod.T, sub_allocator: std.mem.Allocator) !void {
                    _ = tt;
                    _ = sub_allocator;
                    try arenaAllocatorAllocatesCase(std);
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

fn arenaAllocatorTypeIdentityCase(comptime std: type) !void {
    try std.testing.expect(stdz.heap.ArenaAllocator == host_std.heap.ArenaAllocator);
    try std.testing.expect(std.heap.ArenaAllocator == host_std.heap.ArenaAllocator);
    try std.testing.expect(std.heap.ArenaAllocator == stdz.heap.ArenaAllocator);
}

fn arenaAllocatorAllocatesCase(comptime std: type) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    const bytes = try allocator.dupe(u8, "arena");
    try std.testing.expectEqual(@as(usize, 5), bytes.len);
    try std.testing.expect(std.mem.eql(u8, bytes, "arena"));

    const more = try allocator.alloc(u8, 3);
    more[0] = 'z';
    more[1] = 'i';
    more[2] = 'g';
    try std.testing.expect(std.mem.eql(u8, more, "zig"));
}
