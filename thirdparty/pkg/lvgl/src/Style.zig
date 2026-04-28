const glib = @import("glib");
const binding = @import("binding.zig");

const Self = @This();

fn styleProp(value: anytype) binding.StyleProp {
    return switch (@typeInfo(binding.StyleProp)) {
        .@"enum" => @enumFromInt(value),
        else => @as(binding.StyleProp, @intCast(value)),
    };
}

raw: binding.Style,

pub const width_prop: binding.StyleProp = styleProp(binding.LV_STYLE_WIDTH);

pub fn init() Self {
    var self: Self = .{ .raw = undefined };
    binding.lv_style_init(&self.raw);
    return self;
}

pub fn deinit(self: *Self) void {
    binding.lv_style_reset(&self.raw);
}

pub fn reset(self: *Self) void {
    binding.lv_style_reset(&self.raw);
}

pub fn copyFrom(self: *Self, other: *const Self) void {
    binding.lv_style_copy(&self.raw, &other.raw);
}

pub fn mergeFrom(self: *Self, other: *const Self) void {
    binding.lv_style_merge(&self.raw, &other.raw);
}

pub fn setWidth(self: *Self, width: i32) void {
    binding.lv_style_set_width(&self.raw, width);
}

pub fn isEmpty(self: *const Self) bool {
    return binding.lv_style_is_empty(&self.raw);
}

pub fn rawPtr(self: *Self) *binding.Style {
    return &self.raw;
}

pub fn rawConstPtr(self: *const Self) *const binding.Style {
    return &self.raw;
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn lifecycle_starts_empty(_: glib.std.mem.Allocator) !void {
            binding.lv_init();
            defer binding.lv_deinit();

            var a = Self.init();
            defer a.deinit();
            try grt.std.testing.expect(a.isEmpty());

            var b = Self.init();
            defer b.deinit();
            b.copyFrom(&a);
            try grt.std.testing.expect(b.isEmpty());

            b.setWidth(24);
            try grt.std.testing.expect(!b.isEmpty());

            b.mergeFrom(&a);
            try grt.std.testing.expect(!b.isEmpty());
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;

            TestCase.lifecycle_starts_empty(allocator) catch |err| {
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
