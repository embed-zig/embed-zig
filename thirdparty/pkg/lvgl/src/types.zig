const glib = @import("glib");
const binding = @import("binding.zig");

pub const Result = enum(c_int) {
    invalid = 0,
    ok = 1,
};

pub const StyleRes = enum(c_int) {
    not_found = 0,
    found = 1,
};

pub const Align = enum(c_int) {
    default = 0,
    top_left,
    top_mid,
    top_right,
    bottom_left,
    bottom_mid,
    bottom_right,
    left_mid,
    right_mid,
    center,
    out_top_left,
    out_top_mid,
    out_top_right,
    out_bottom_left,
    out_bottom_mid,
    out_bottom_right,
    out_left_top,
    out_left_mid,
    out_left_bottom,
    out_right_top,
    out_right_mid,
    out_right_bottom,
};

pub const Dir = packed struct(u8) {
    left: bool = false,
    right: bool = false,
    top: bool = false,
    bottom: bool = false,
    _padding: u4 = 0,

    pub fn fromInt(value: u8) @This() {
        return @bitCast(value);
    }

    pub fn toInt(self: @This()) u8 {
        return @bitCast(self);
    }

    pub const none = @This(){};
    pub const hor = @This(){ .left = true, .right = true };
    pub const ver = @This(){ .top = true, .bottom = true };
    pub const all = @This(){ .left = true, .right = true, .top = true, .bottom = true };
};

pub const Opa = u8;

pub const opa = struct {
    pub const transparent: Opa = 0;
    pub const cover: Opa = 255;
    pub const pct10: Opa = 25;
    pub const pct20: Opa = 51;
    pub const pct30: Opa = 76;
    pub const pct40: Opa = 102;
    pub const pct50: Opa = 127;
    pub const pct60: Opa = 153;
    pub const pct70: Opa = 178;
    pub const pct80: Opa = 204;
    pub const pct90: Opa = 229;
    pub const pct100: Opa = 255;
};

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn base_enums_match_imported_bindings(_: glib.std.mem.Allocator) !void {
            try grt.std.testing.expect(@intFromEnum(Result.invalid) == 0);
            try grt.std.testing.expect(@intFromEnum(Result.ok) == 1);
            try grt.std.testing.expect(@intFromEnum(StyleRes.not_found) == 0);
            try grt.std.testing.expect(@intFromEnum(StyleRes.found) == 1);

            try grt.std.testing.expect(@intFromEnum(Align.center) == 9);
            try grt.std.testing.expectEqual(@as(u8, 0x0F), Dir.all.toInt());
            try grt.std.testing.expectEqual(@as(binding.Opa, 255), opa.cover);
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;

            TestCase.base_enums_match_imported_bindings(allocator) catch |err| {
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
