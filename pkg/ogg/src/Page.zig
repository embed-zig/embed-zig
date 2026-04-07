const binding = @import("binding.zig");
const root = @import("root");
const testing_api = if (@hasDecl(root, "testing")) root.testing else struct {
    pub const TestRunner = void;
    pub const T = void;
};

const Self = @This();

header: [*c]u8,
header_len: c_long,
body: [*c]u8,
body_len: c_long,

pub fn version(self: *const Self) c_int {
    return binding.ogg_page_version(@ptrCast(self));
}

pub fn continued(self: *const Self) bool {
    return binding.ogg_page_continued(@ptrCast(self)) != 0;
}

pub fn bos(self: *const Self) bool {
    return binding.ogg_page_bos(@ptrCast(self)) != 0;
}

pub fn eos(self: *const Self) bool {
    return binding.ogg_page_eos(@ptrCast(self)) != 0;
}

pub fn granulePos(self: *const Self) i64 {
    return binding.ogg_page_granulepos(@ptrCast(self));
}

pub fn serialNo(self: *const Self) c_int {
    return binding.ogg_page_serialno(@ptrCast(self));
}

pub fn pageNo(self: *const Self) c_long {
    return binding.ogg_page_pageno(@ptrCast(self));
}

pub fn packets(self: *const Self) c_int {
    return binding.ogg_page_packets(@ptrCast(self));
}

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    const TestCase = struct {
        fn testLayoutMatchesRawOggPage() !void {
            const testing = lib.testing;

            try testing.expectEqual(@sizeOf(binding.Page), @sizeOf(Self));
            try testing.expectEqual(@alignOf(binding.Page), @alignOf(Self));

            _ = Self.version;
            _ = Self.serialNo;
            _ = Self.pageNo;
            _ = Self.packets;
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            TestCase.testLayoutMatchesRawOggPage() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: lib.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}
