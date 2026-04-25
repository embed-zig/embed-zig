const stdz = @import("stdz");
const std = @import("std");
const testing_mod = @import("testing");

pub fn make(comptime lib: type) testing_mod.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: stdz.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_mod.T, allocator: stdz.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.run("arena_allocator_type_identity", testing_mod.TestRunner.fromFn(lib, 8 * 1024, struct {
                fn run(tt: *testing_mod.T, sub_allocator: lib.mem.Allocator) !void {
                    _ = tt;
                    _ = sub_allocator;
                    try arenaAllocatorTypeIdentityCase(lib);
                }
            }.run));
            t.run("arena_allocator_allocates", testing_mod.TestRunner.fromFn(lib, 16 * 1024, struct {
                fn run(tt: *testing_mod.T, sub_allocator: lib.mem.Allocator) !void {
                    _ = tt;
                    _ = sub_allocator;
                    try arenaAllocatorAllocatesCase(lib);
                }
            }.run));
            return t.wait();
        }

        pub fn deinit(self: *@This(), allocator: stdz.mem.Allocator) void {
            _ = allocator;
            lib.testing.allocator.destroy(self);
        }
    };

    const runner = lib.testing.allocator.create(Runner) catch @panic("OOM");
    runner.* = .{};
    return testing_mod.TestRunner.make(Runner).new(runner);
}

fn arenaAllocatorTypeIdentityCase(comptime lib: type) !void {
    try lib.testing.expect(stdz.heap.ArenaAllocator == std.heap.ArenaAllocator);
    try lib.testing.expect(lib.heap.ArenaAllocator == std.heap.ArenaAllocator);
    try lib.testing.expect(lib.heap.ArenaAllocator == stdz.heap.ArenaAllocator);
}

fn arenaAllocatorAllocatesCase(comptime lib: type) !void {
    var arena = lib.heap.ArenaAllocator.init(lib.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    const bytes = try allocator.dupe(u8, "arena");
    try lib.testing.expectEqual(@as(usize, 5), bytes.len);
    try lib.testing.expect(lib.mem.eql(u8, bytes, "arena"));

    const more = try allocator.alloc(u8, 3);
    more[0] = 'z';
    more[1] = 'i';
    more[2] = 'g';
    try lib.testing.expect(lib.mem.eql(u8, more, "zig"));
}
