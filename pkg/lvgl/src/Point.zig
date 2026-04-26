const glib = @import("glib");
const binding = @import("binding.zig");

const Self = @This();

x: i32,
y: i32,

pub fn init(x: i32, y: i32) Self {
    return .{ .x = x, .y = y };
}

pub fn set(self: *Self, x: i32, y: i32) void {
    var raw = self.toBinding();
    binding.lv_point_set(&raw, x, y);
    self.* = fromBinding(raw);
}

pub fn swap(self: *Self, other: *Self) void {
    var lhs = self.toBinding();
    var rhs = other.toBinding();
    binding.lv_point_swap(&lhs, &rhs);
    self.* = fromBinding(lhs);
    other.* = fromBinding(rhs);
}

pub fn toBinding(self: *const Self) binding.Point {
    return .{
        .x = self.x,
        .y = self.y,
    };
}

pub fn fromBinding(raw: binding.Point) Self {
    return .{
        .x = raw.x,
        .y = raw.y,
    };
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn layout_and_mutation_helpers(_: glib.std.mem.Allocator) !void {
            var p = Self.init(1, 2);
            p.set(10, 20);
            try grt.std.testing.expectEqual(@as(i32, 10), p.x);
            try grt.std.testing.expectEqual(@as(i32, 20), p.y);

            var q = Self.init(3, 4);
            p.swap(&q);
            try grt.std.testing.expectEqual(@as(i32, 3), p.x);
            try grt.std.testing.expectEqual(@as(i32, 4), p.y);
            try grt.std.testing.expectEqual(@as(i32, 10), q.x);
            try grt.std.testing.expectEqual(@as(i32, 20), q.y);
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;

            TestCase.layout_and_mutation_helpers(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: glib.std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return glib.testing.TestRunner.make(Runner).new(&Holder.runner);
}
