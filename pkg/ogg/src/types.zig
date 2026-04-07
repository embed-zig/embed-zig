const root = @import("root");
const testing_api = if (@hasDecl(root, "testing")) root.testing else struct {
    pub const TestRunner = void;
    pub const T = void;
};

pub const PageOutResult = enum {
    page_ready,
    need_more_data,
    sync_lost,
};

pub const PacketOutResult = enum {
    packet_ready,
    need_more_data,
    error_or_hole,
};

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    const TestCase = struct {
        fn testResultEnumsStayStable() !void {
            const testing = lib.testing;

            try testing.expectEqual(@as(usize, 0), @as(usize, @intFromEnum(PageOutResult.page_ready)));
            try testing.expectEqual(@as(usize, 1), @as(usize, @intFromEnum(PageOutResult.need_more_data)));
            try testing.expectEqual(@as(usize, 2), @as(usize, @intFromEnum(PageOutResult.sync_lost)));

            try testing.expectEqual(@as(usize, 0), @as(usize, @intFromEnum(PacketOutResult.packet_ready)));
            try testing.expectEqual(@as(usize, 1), @as(usize, @intFromEnum(PacketOutResult.need_more_data)));
            try testing.expectEqual(@as(usize, 2), @as(usize, @intFromEnum(PacketOutResult.error_or_hole)));
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

            TestCase.testResultEnumsStayStable() catch |err| {
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
