const embed = @import("embed");
const binding = @import("binding.zig");
const Page = @import("Page.zig");
const PageOutResult = @import("types.zig").PageOutResult;

const Self = @This();

state: binding.SyncState,

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

pub fn buffer(self: *Self, size: usize) ?[]u8 {
    const ptr = binding.ogg_sync_buffer(&self.state, @intCast(size));
    if (ptr == null) return null;
    return ptr[0..size];
}

pub fn wrote(self: *Self, bytes: usize) !void {
    if (binding.ogg_sync_wrote(&self.state, @intCast(bytes)) != 0) {
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
    const std = @import("std");
    const testing = std.testing;

    var sync = Self.init();
    defer sync.deinit();

    const buf = sync.buffer(4096);
    try testing.expect(buf != null);
    try testing.expect(buf.?.len == 4096);
}

test "ogg/unit_tests/Sync/pageOut_returns_need_more_data_on_empty_state" {
    const std = @import("std");
    const testing = std.testing;

    var sync = Self.init();
    defer sync.deinit();

    var page: Page = undefined;
    const result = sync.pageOut(&page);
    try testing.expectEqual(PageOutResult.need_more_data, result);
}
