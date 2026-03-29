//! Allocator wrapper for tests that can enforce a live-byte limit and
//! capture peak concurrent live usage.

const embed = @import("embed");
const atomic = embed.atomic;
const mem = embed.mem;

const AtomicBool = atomic.Value(bool);
const Self = @This();

pub const Stats = struct {
    peak_live_bytes: usize = 0,
};

backing: mem.Allocator,
memory_limit: ?usize,
lock_state: AtomicBool = AtomicBool.init(false),
live_bytes: usize = 0,
peak_live_bytes: usize = 0,

pub fn init(backing: mem.Allocator, memory_limit: ?usize) Self {
    return .{
        .backing = backing,
        .memory_limit = memory_limit,
    };
}

pub fn allocator(self: *Self) mem.Allocator {
    return .{
        .ptr = self,
        .vtable = &vtable,
    };
}

pub fn stats(self: *const Self) Stats {
    const mutable = @constCast(self);
    mutable.lock();
    defer mutable.unlock();
    return .{
        .peak_live_bytes = self.peak_live_bytes,
    };
}

pub fn peakLiveBytes(self: *const Self) usize {
    return self.stats().peak_live_bytes;
}

fn lock(self: *Self) void {
    while (true) {
        if (self.lock_state.cmpxchgStrong(false, true, .acquire, .acquire) == null) return;
        while (self.lock_state.load(.acquire)) {}
    }
}

fn unlock(self: *Self) void {
    self.lock_state.store(false, .release);
}

fn canGrow(self: *const Self, delta: usize) bool {
    if (delta == 0) return true;
    const limit = self.memory_limit orelse return true;
    if (self.live_bytes > limit) return false;
    return delta <= limit - self.live_bytes;
}

fn recordGrow(self: *Self, delta: usize) void {
    if (delta == 0) return;
    self.live_bytes += delta;
    if (self.live_bytes > self.peak_live_bytes) {
        self.peak_live_bytes = self.live_bytes;
    }
}

fn recordShrink(self: *Self, delta: usize) void {
    if (delta == 0) return;
    if (delta >= self.live_bytes) {
        self.live_bytes = 0;
        return;
    }
    self.live_bytes -= delta;
}

fn alloc(ptr: *anyopaque, len: usize, alignment: mem.Alignment, ret_addr: usize) ?[*]u8 {
    const self: *Self = @ptrCast(@alignCast(ptr));
    self.lock();
    defer self.unlock();

    if (!self.canGrow(len)) return null;

    const memory = self.backing.rawAlloc(len, alignment, ret_addr) orelse return null;
    self.recordGrow(len);
    return memory;
}

fn resize(ptr: *anyopaque, memory: []u8, alignment: mem.Alignment, new_len: usize, ret_addr: usize) bool {
    const self: *Self = @ptrCast(@alignCast(ptr));
    self.lock();
    defer self.unlock();

    if (new_len > memory.len and !self.canGrow(new_len - memory.len)) return false;
    if (!self.backing.rawResize(memory, alignment, new_len, ret_addr)) return false;

    if (new_len > memory.len) {
        self.recordGrow(new_len - memory.len);
    } else {
        self.recordShrink(memory.len - new_len);
    }
    return true;
}

fn remap(ptr: *anyopaque, memory: []u8, alignment: mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    const self: *Self = @ptrCast(@alignCast(ptr));
    self.lock();
    defer self.unlock();

    if (new_len > memory.len and !self.canGrow(new_len - memory.len)) return null;
    const mapped = self.backing.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;

    if (new_len > memory.len) {
        self.recordGrow(new_len - memory.len);
    } else {
        self.recordShrink(memory.len - new_len);
    }
    return mapped;
}

fn free(ptr: *anyopaque, memory: []u8, alignment: mem.Alignment, ret_addr: usize) void {
    const self: *Self = @ptrCast(@alignCast(ptr));
    self.lock();
    defer self.unlock();

    self.backing.rawFree(memory, alignment, ret_addr);
    self.recordShrink(memory.len);
}

const vtable: mem.Allocator.VTable = .{
    .alloc = alloc,
    .resize = resize,
    .remap = remap,
    .free = free,
};

test "testing/unit_tests/TestingAllocator/enforces_limit_and_tracks_peak" {
    const std = @import("std");

    var allocator_state = Self.init(std.testing.allocator, 24);
    const alloc_inst = allocator_state.allocator();

    const first = try alloc_inst.alloc(u8, 16);
    defer alloc_inst.free(first);

    try std.testing.expectEqual(@as(usize, 16), allocator_state.peakLiveBytes());

    try std.testing.expectError(error.OutOfMemory, alloc_inst.alloc(u8, 16));
    try std.testing.expectEqual(@as(usize, 16), allocator_state.peakLiveBytes());

    const second = try alloc_inst.alloc(u8, 8);
    defer alloc_inst.free(second);

    const current = allocator_state.stats();
    try std.testing.expectEqual(@as(usize, 24), current.peak_live_bytes);
}

test "testing/unit_tests/TestingAllocator/tracks_peak_concurrent_live_bytes" {
    const std = @import("std");

    const Sync = struct {
        mutex: std.Thread.Mutex = .{},
        cond: std.Thread.Condition = .{},
        ready_count: usize = 0,
        release: bool = false,
    };

    const Worker = struct {
        fn run(sync: *Sync, alloc_inst: mem.Allocator) !void {
            const bytes = try alloc_inst.alloc(u8, 16);
            defer alloc_inst.free(bytes);

            sync.mutex.lock();
            sync.ready_count += 1;
            sync.cond.broadcast();
            while (!sync.release) {
                sync.cond.wait(&sync.mutex);
            }
            sync.mutex.unlock();
        }
    };

    var allocator_state = Self.init(std.heap.page_allocator, null);
    const alloc_inst = allocator_state.allocator();
    var sync: Sync = .{};

    const t1 = try std.Thread.spawn(.{}, Worker.run, .{ &sync, alloc_inst });
    const t2 = try std.Thread.spawn(.{}, Worker.run, .{ &sync, alloc_inst });

    sync.mutex.lock();
    while (sync.ready_count < 2) {
        sync.cond.wait(&sync.mutex);
    }
    try std.testing.expectEqual(@as(usize, 32), allocator_state.peakLiveBytes());
    sync.release = true;
    sync.cond.broadcast();
    sync.mutex.unlock();

    t1.join();
    t2.join();

    try std.testing.expectEqual(@as(usize, 32), allocator_state.peakLiveBytes());
}
