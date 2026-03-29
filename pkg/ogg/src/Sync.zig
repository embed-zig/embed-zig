const binding = @import("binding.zig");
const Page = @import("Page.zig");
const PageOutResult = @import("types.zig").PageOutResult;

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
    _ = binding.ogg_sync_init(&self.state);
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

test "ogg/unit_tests/Sync/state_lifecycle" {
    var sync = Self.init();
    defer sync.deinit();

    sync.reset();
}

test "ogg/unit_tests/Sync/buffer_allocation" {
    const testing = @import("std").testing;

    var sync = Self.init();
    defer sync.deinit();

    const buf = try sync.buffer(4096);
    try testing.expectEqual(@as(usize, 4096), buf.len);
}

test "ogg/unit_tests/Sync/pageOut_returns_need_more_data_on_empty_state" {
    const testing = @import("std").testing;

    var sync = Self.init();
    defer sync.deinit();

    var page: Page = undefined;
    const result = sync.pageOut(&page);
    try testing.expectEqual(PageOutResult.need_more_data, result);
}

test "ogg/unit_tests/Sync/buffer_rejects_sizes_that_do_not_fit_c_long" {
    const testing = @import("std").testing;

    var sync = Self.init();
    defer sync.deinit();

    const too_large = @as(usize, @intCast(maxInt(c_long))) + 1;
    try testing.expectError(error.SizeTooLarge, sync.buffer(too_large));
}

test "ogg/unit_tests/Sync/wrote_rejects_sizes_that_do_not_fit_c_long" {
    const testing = @import("std").testing;

    var sync = Self.init();
    defer sync.deinit();

    const too_large = @as(usize, @intCast(maxInt(c_long))) + 1;
    try testing.expectError(error.SizeTooLarge, sync.wrote(too_large));
}

test "ogg/unit_tests/Sync/wrote_returns_error_when_bytes_exceed_buffer_capacity" {
    const testing = @import("std").testing;

    var sync = Self.init();
    defer sync.deinit();

    try testing.expectError(error.SyncWroteFailed, sync.wrote(1));
}

test "ogg/unit_tests/Sync/buffer_propagates_null_pointer_failure" {
    const testing = @import("std").testing;

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

test "ogg/unit_tests/Sync/buffer_then_wrote_forms_minimal_happy_path" {
    const testing = @import("std").testing;

    var sync = Self.init();
    defer sync.deinit();

    const buf = try sync.buffer(1);
    buf[0] = 0;
    try sync.wrote(1);

    var page: Page = undefined;
    try testing.expectEqual(PageOutResult.need_more_data, sync.pageOut(&page));
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
