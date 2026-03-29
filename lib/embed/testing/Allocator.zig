//! Transparent testing allocator wrapper with allocation statistics.

const std = @import("std");

/// Stats for the transparent `testing.allocator` wrapper.
///
/// These counters reflect successful allocator vtable operations observed by
/// the wrapper. High-level operations such as `realloc` may internally fall
/// back to `alloc + free`, so peak and cumulative counters can exceed the
/// logical final slice length.
pub const Stats = struct {
    live_bytes: usize = 0,
    peak_live_bytes: usize = 0,
    total_allocated_bytes: usize = 0,
    total_freed_bytes: usize = 0,
    alloc_count: usize = 0,
    free_count: usize = 0,
    resize_count: usize = 0,
    remap_count: usize = 0,
};

const AtomicUsize = std.atomic.Value(usize);

backing: std.mem.Allocator,
live_bytes: AtomicUsize = AtomicUsize.init(0),
peak_live_bytes: AtomicUsize = AtomicUsize.init(0),
total_allocated_bytes: AtomicUsize = AtomicUsize.init(0),
total_freed_bytes: AtomicUsize = AtomicUsize.init(0),
alloc_count: AtomicUsize = AtomicUsize.init(0),
free_count: AtomicUsize = AtomicUsize.init(0),
resize_count: AtomicUsize = AtomicUsize.init(0),
remap_count: AtomicUsize = AtomicUsize.init(0),

const Self = @This();

pub fn init(backing: std.mem.Allocator) Self {
    return .{ .backing = backing };
}

pub fn allocator(self: *Self) std.mem.Allocator {
    return .{
        .ptr = self,
        .vtable = &vtable,
    };
}

pub fn stats(self: *const Self) Stats {
    return .{
        .live_bytes = self.live_bytes.load(.acquire),
        .peak_live_bytes = self.peak_live_bytes.load(.acquire),
        .total_allocated_bytes = self.total_allocated_bytes.load(.acquire),
        .total_freed_bytes = self.total_freed_bytes.load(.acquire),
        .alloc_count = self.alloc_count.load(.acquire),
        .free_count = self.free_count.load(.acquire),
        .resize_count = self.resize_count.load(.acquire),
        .remap_count = self.remap_count.load(.acquire),
    };
}

pub fn resetStats(self: *Self) void {
    self.live_bytes.store(0, .release);
    self.peak_live_bytes.store(0, .release);
    self.total_allocated_bytes.store(0, .release);
    self.total_freed_bytes.store(0, .release);
    self.alloc_count.store(0, .release);
    self.free_count.store(0, .release);
    self.resize_count.store(0, .release);
    self.remap_count.store(0, .release);
}

fn recordGrow(self: *Self, delta: usize) void {
    if (delta == 0) return;
    const live = self.live_bytes.fetchAdd(delta, .acq_rel) + delta;
    _ = self.total_allocated_bytes.fetchAdd(delta, .acq_rel);
    self.updatePeakLiveBytes(live);
}

fn recordShrink(self: *Self, delta: usize) void {
    if (delta == 0) return;
    _ = self.live_bytes.fetchSub(delta, .acq_rel);
    _ = self.total_freed_bytes.fetchAdd(delta, .acq_rel);
}

fn updatePeakLiveBytes(self: *Self, live: usize) void {
    var current = self.peak_live_bytes.load(.acquire);
    while (live > current) {
        const observed = self.peak_live_bytes.cmpxchgStrong(current, live, .acq_rel, .acquire);
        if (observed == null) return;
        current = observed.?;
    }
}

fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    const self: *Self = @ptrCast(@alignCast(ptr));
    const memory = self.backing.rawAlloc(len, alignment, ret_addr) orelse return null;
    self.recordGrow(len);
    _ = self.alloc_count.fetchAdd(1, .acq_rel);
    return memory;
}

fn resize(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
    const self: *Self = @ptrCast(@alignCast(ptr));
    if (!self.backing.rawResize(memory, alignment, new_len, ret_addr)) return false;

    if (new_len >= memory.len) {
        self.recordGrow(new_len - memory.len);
    } else {
        self.recordShrink(memory.len - new_len);
    }
    _ = self.resize_count.fetchAdd(1, .acq_rel);
    return true;
}

fn remap(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    const self: *Self = @ptrCast(@alignCast(ptr));
    const mapped = self.backing.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;

    if (new_len >= memory.len) {
        self.recordGrow(new_len - memory.len);
    } else {
        self.recordShrink(memory.len - new_len);
    }
    _ = self.remap_count.fetchAdd(1, .acq_rel);
    return mapped;
}

fn free(ptr: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
    const self: *Self = @ptrCast(@alignCast(ptr));
    self.backing.rawFree(memory, alignment, ret_addr);
    self.recordShrink(memory.len);
    _ = self.free_count.fetchAdd(1, .acq_rel);
}

const vtable: std.mem.Allocator.VTable = .{
    .alloc = alloc,
    .resize = resize,
    .remap = remap,
    .free = free,
};

test "embed/unit_tests/testing/Allocator/stats_reflect_alloc_free_and_realloc_activity" {
    var allocator_state = Self.init(std.testing.allocator);
    const alloc_inst = allocator_state.allocator();

    allocator_state.resetStats();
    try std.testing.expectEqual(Stats{}, allocator_state.stats());

    var bytes = try alloc_inst.alloc(u8, 16);
    defer alloc_inst.free(bytes);

    var current = allocator_state.stats();
    try std.testing.expectEqual(@as(usize, 16), current.live_bytes);
    try std.testing.expectEqual(@as(usize, 16), current.peak_live_bytes);
    try std.testing.expectEqual(@as(usize, 16), current.total_allocated_bytes);
    try std.testing.expectEqual(@as(usize, 0), current.total_freed_bytes);
    try std.testing.expectEqual(@as(usize, 1), current.alloc_count);
    try std.testing.expectEqual(@as(usize, 0), current.free_count);

    bytes = try alloc_inst.realloc(bytes, 24);
    current = allocator_state.stats();
    try std.testing.expectEqual(@as(usize, 24), current.live_bytes);
    try std.testing.expect(current.peak_live_bytes >= 24);
    try std.testing.expect(current.total_allocated_bytes >= 24);

    bytes = try alloc_inst.realloc(bytes, 8);
    current = allocator_state.stats();
    try std.testing.expectEqual(@as(usize, 8), current.live_bytes);
    try std.testing.expect(current.peak_live_bytes >= 24);
    try std.testing.expect(current.total_allocated_bytes >= 24);
    try std.testing.expect(current.total_freed_bytes >= 16);
}

test "embed/unit_tests/testing/Allocator/resetStats_clears_counters" {
    var allocator_state = Self.init(std.testing.allocator);
    const alloc_inst = allocator_state.allocator();

    allocator_state.resetStats();

    const bytes = try alloc_inst.alloc(u8, 8);
    alloc_inst.free(bytes);

    var current = allocator_state.stats();
    try std.testing.expectEqual(@as(usize, 8), current.total_allocated_bytes);
    try std.testing.expectEqual(@as(usize, 8), current.total_freed_bytes);
    try std.testing.expectEqual(@as(usize, 1), current.alloc_count);
    try std.testing.expectEqual(@as(usize, 1), current.free_count);

    allocator_state.resetStats();
    current = allocator_state.stats();
    try std.testing.expectEqual(Stats{}, current);
}
