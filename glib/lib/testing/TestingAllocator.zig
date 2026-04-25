//! Allocator wrapper for tests that can enforce a live-byte limit and
//! capture peak concurrent live usage.

const builtin = @import("builtin");
const stdz = @import("stdz");
const atomic = stdz.atomic;
const mem = stdz.mem;
const T = @import("T.zig");
const TestRunnerApi = @import("TestRunner.zig");

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

pub fn TestRunner(comptime lib: type) TestRunnerApi {
    if (builtin.target.os.tag == .freestanding) {
        const Runner = struct {
            pub fn init(self: *@This(), allocator_arg: lib.mem.Allocator) !void {
                _ = self;
                _ = allocator_arg;
            }

            pub fn run(self: *@This(), t: *T, allocator_arg: mem.Allocator) bool {
                _ = self;
                _ = t;
                _ = allocator_arg;
                return true;
            }

            pub fn deinit(self: *@This(), allocator_arg: mem.Allocator) void {
                _ = self;
                _ = allocator_arg;
            }
        };

        const Holder = struct {
            var runner: Runner = .{};
        };
        return TestRunnerApi.make(Runner).new(&Holder.runner);
    }

    const TestCase = struct {
        fn testEnforcesLimitAndTracksPeak() !void {
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

        fn testTracksPeakConcurrentLiveBytes() !void {
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

        fn testResizeAndRemapRespectLimit() !void {
            const std = @import("std");

            const FixedBufferAllocator = struct {
                storage: [64]u8 = undefined,
                allocated_len: usize = 0,
                resize_calls: usize = 0,
                remap_calls: usize = 0,

                fn allocator(self: *@This()) mem.Allocator {
                    return .{
                        .ptr = self,
                        .vtable = &backing_vtable,
                    };
                }

                fn backingAlloc(ptr: *anyopaque, len: usize, alignment: mem.Alignment, ret_addr: usize) ?[*]u8 {
                    const self: *@This() = @ptrCast(@alignCast(ptr));
                    _ = alignment;
                    _ = ret_addr;
                    if (self.allocated_len != 0 or len > self.storage.len) return null;
                    self.allocated_len = len;
                    return self.storage[0..len].ptr;
                }

                fn backingResize(ptr: *anyopaque, memory: []u8, alignment: mem.Alignment, new_len: usize, ret_addr: usize) bool {
                    const self: *@This() = @ptrCast(@alignCast(ptr));
                    _ = alignment;
                    _ = ret_addr;
                    self.resize_calls += 1;
                    if (@intFromPtr(memory.ptr) != @intFromPtr(self.storage[0..].ptr)) return false;
                    if (new_len > self.storage.len) return false;
                    self.allocated_len = new_len;
                    return true;
                }

                fn backingRemap(ptr: *anyopaque, memory: []u8, alignment: mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
                    const self: *@This() = @ptrCast(@alignCast(ptr));
                    _ = alignment;
                    _ = ret_addr;
                    self.remap_calls += 1;
                    if (@intFromPtr(memory.ptr) != @intFromPtr(self.storage[0..].ptr)) return null;
                    if (new_len > self.storage.len) return null;
                    self.allocated_len = new_len;
                    return self.storage[0..new_len].ptr;
                }

                fn backingFree(ptr: *anyopaque, memory: []u8, alignment: mem.Alignment, ret_addr: usize) void {
                    const self: *@This() = @ptrCast(@alignCast(ptr));
                    _ = memory;
                    _ = alignment;
                    _ = ret_addr;
                    self.allocated_len = 0;
                }

                const backing_vtable: mem.Allocator.VTable = .{
                    .alloc = backingAlloc,
                    .resize = backingResize,
                    .remap = backingRemap,
                    .free = backingFree,
                };
            };

            var backing = FixedBufferAllocator{};
            var allocator_state = Self.init(backing.allocator(), 16);
            const alloc_inst = allocator_state.allocator();

            var bytes = try alloc_inst.alloc(u8, 12);
            defer alloc_inst.free(bytes);

            try std.testing.expectEqual(@as(usize, 12), allocator_state.peakLiveBytes());

            try std.testing.expect(!alloc_inst.resize(bytes, 20));
            try std.testing.expectEqual(@as(usize, 0), backing.resize_calls);
            try std.testing.expectEqual(@as(usize, 12), allocator_state.peakLiveBytes());

            try std.testing.expect(alloc_inst.resize(bytes, 8));
            bytes = bytes[0..8];
            try std.testing.expectEqual(@as(usize, 1), backing.resize_calls);

            bytes = alloc_inst.remap(bytes, 16) orelse return error.ExpectedRemap;
            try std.testing.expectEqual(@as(usize, 1), backing.remap_calls);
            try std.testing.expectEqual(@as(usize, 16), allocator_state.peakLiveBytes());

            try std.testing.expect(alloc_inst.remap(bytes, 17) == null);
            try std.testing.expectEqual(@as(usize, 1), backing.remap_calls);
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), gpa: lib.mem.Allocator) !void {
            _ = self;
            _ = gpa;
        }

        pub fn run(self: *@This(), t: *T, gpa: lib.mem.Allocator) bool {
            _ = self;
            _ = gpa;

            TestCase.testEnforcesLimitAndTracksPeak() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.testTracksPeakConcurrentLiveBytes() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.testResizeAndRemapRespectLimit() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), gpa: lib.mem.Allocator) void {
            _ = self;
            _ = gpa;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return TestRunnerApi.make(Runner).new(&Holder.runner);
}
