const binding = @import("binding.zig");
const Page = @import("Page.zig");
const PageOutResult = @import("types.zig").PageOutResult;
const testing_api = @import("testing");

const Self = @This();

state: binding.SyncState,

pub const BufferError = error{
    SizeTooLarge,
    SyncBufferFailed,
};

pub const WroteError = error{
    SizeTooLarge,
    SyncWroteFailed,
};

pub fn init() Self {
    var self = Self{ .state = undefined };
    // libogg documents ogg_sync_init() as always returning 0 after
    // initializing the sync state to a known value.
    if (binding.ogg_sync_init(&self.state) != 0) {
        @panic("libogg ogg_sync_init invariant violated");
    }
    return self;
}

pub fn deinit(self: *Self) void {
    _ = binding.ogg_sync_clear(&self.state);
}

pub fn reset(self: *Self) void {
    _ = binding.ogg_sync_reset(&self.state);
}

pub fn buffer(self: *Self, size: usize) BufferError![]u8 {
    return bufferWith(self, size, binding.ogg_sync_buffer);
}

fn bufferWith(self: *Self, size: usize, buffer_fn: anytype) BufferError![]u8 {
    const ptr = buffer_fn(&self.state, try intCastCLong(size)) orelse {
        return error.SyncBufferFailed;
    };
    return ptr[0..size];
}

pub fn wrote(self: *Self, bytes: usize) WroteError!void {
    if (binding.ogg_sync_wrote(&self.state, try intCastCLong(bytes)) != 0) {
        return error.SyncWroteFailed;
    }
}

pub fn pageOut(self: *Self, page: *Page) PageOutResult {
    const ret = binding.ogg_sync_pageout(&self.state, @ptrCast(page));
    return switch (ret) {
        1 => .page_ready,
        0 => .need_more_data,
        else => .sync_lost,
    };
}

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    const TestCase = struct {
        fn testStateLifecycle() !void {
            var sync = Self.init();
            defer sync.deinit();

            sync.reset();
        }

        fn testBufferAllocation() !void {
            const testing = lib.testing;

            var sync = Self.init();
            defer sync.deinit();

            const buf = try sync.buffer(4096);
            try testing.expectEqual(@as(usize, 4096), buf.len);
        }

        fn testPageOutReturnsNeedMoreDataOnEmptyState() !void {
            const testing = lib.testing;

            var sync = Self.init();
            defer sync.deinit();

            var page: Page = undefined;
            const result = sync.pageOut(&page);
            try testing.expectEqual(PageOutResult.need_more_data, result);
        }

        fn testBufferRejectsSizesThatDoNotFitCLong() !void {
            const testing = lib.testing;

            var sync = Self.init();
            defer sync.deinit();

            const too_large = @as(usize, @intCast(maxInt(c_long))) + 1;
            try testing.expectError(error.SizeTooLarge, sync.buffer(too_large));
        }

        fn testWroteRejectsSizesThatDoNotFitCLong() !void {
            const testing = lib.testing;

            var sync = Self.init();
            defer sync.deinit();

            const too_large = @as(usize, @intCast(maxInt(c_long))) + 1;
            try testing.expectError(error.SizeTooLarge, sync.wrote(too_large));
        }

        fn testWroteReturnsErrorWhenBytesExceedBufferCapacity() !void {
            const testing = lib.testing;

            var sync = Self.init();
            defer sync.deinit();

            try testing.expectError(error.SyncWroteFailed, sync.wrote(1));
        }

        fn testBufferPropagatesNullPointerFailure() !void {
            const testing = lib.testing;

            const FailingBinding = struct {
                fn ogg_sync_buffer(_: *binding.SyncState, _: c_long) ?[*c]u8 {
                    return null;
                }
            };

            var sync = Self.init();
            defer sync.deinit();

            try testing.expectError(
                error.SyncBufferFailed,
                bufferWith(&sync, 16, FailingBinding.ogg_sync_buffer),
            );
        }

        fn testBufferThenWroteFormsMinimalHappyPath() !void {
            const testing = lib.testing;

            var sync = Self.init();
            defer sync.deinit();

            const buf = try sync.buffer(1);
            buf[0] = 0;
            try sync.wrote(1);

            var page: Page = undefined;
            try testing.expectEqual(PageOutResult.need_more_data, sync.pageOut(&page));
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

            TestCase.testStateLifecycle() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.testBufferAllocation() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.testPageOutReturnsNeedMoreDataOnEmptyState() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.testBufferRejectsSizesThatDoNotFitCLong() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.testWroteRejectsSizesThatDoNotFitCLong() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.testWroteReturnsErrorWhenBytesExceedBufferCapacity() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.testBufferPropagatesNullPointerFailure() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.testBufferThenWroteFormsMinimalHappyPath() catch |err| {
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

fn intCastCLong(value: usize) error{SizeTooLarge}!c_long {
    const max_c_long: usize = @intCast(maxInt(c_long));
    if (value > max_c_long) return error.SizeTooLarge;
    return @intCast(value);
}

fn maxInt(comptime T: type) comptime_int {
    const info = @typeInfo(T).int;
    return switch (info.signedness) {
        .signed => (@as(comptime_int, 1) << (info.bits - 1)) - 1,
        .unsigned => (@as(comptime_int, 1) << info.bits) - 1,
    };
}
