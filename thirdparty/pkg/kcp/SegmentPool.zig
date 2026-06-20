//! Fixed-size KCP segment allocator backed by a shared segment pool.

const glib = @import("glib");
const kcp = @import("../kcp.zig");

const invalid_index = ~@as(u32, 0);
const max_usize = ~@as(usize, 0);

pub fn make(comptime grt: type) type {
    return struct {
        const Self = @This();
        const std = grt.std;
        const Mutex = grt.sync.Mutex;

        const Header = extern struct {
            tag: u32,
            index: u32,
            total_len: usize,
        };

        const pooled_tag: u32 = 0x4b435050;
        const fallback_tag: u32 = 0x4b435046;
        const allocation_alignment = std.mem.Alignment.fromByteUnits(@max(@alignOf(Header), @alignOf(kcp.c.IKCPSEG)));

        backing_allocator: std.mem.Allocator,
        mutex: Mutex = .{},
        blocks: []u8 = &.{},
        free_next: []u32 = &.{},
        free_head: u32 = invalid_index,
        segment_size: usize = 0,
        slot_size: usize = 0,
        available_segments: usize = 0,
        pooled_allocs: usize = 0,
        pooled_frees: usize = 0,
        fallback_allocs: usize = 0,
        fallback_frees: usize = 0,
        allocation_failures: usize = 0,

        pub const Snapshot = struct {
            segment_size: usize,
            reserved_segments: usize,
            available_segments: usize,
            pooled_allocs: usize,
            pooled_frees: usize,
            fallback_allocs: usize,
            fallback_frees: usize,
            allocation_failures: usize,
        };

        pub fn init(
            backing_allocator: std.mem.Allocator,
            mss: usize,
            reserve_segments: usize,
        ) !Self {
            if (reserve_segments > std.math.maxInt(u32)) return error.KcpPoolTooLarge;

            if (mss > max_usize - @sizeOf(kcp.c.IKCPSEG)) return error.KcpPoolTooLarge;
            const segment_size = @sizeOf(kcp.c.IKCPSEG) + mss;
            if (segment_size > max_usize - @sizeOf(Header)) return error.KcpPoolTooLarge;
            const slot_size = @sizeOf(Header) + segment_size;

            var blocks: []u8 = &.{};
            var free_next: []u32 = &.{};
            if (reserve_segments > 0) {
                if (slot_size > max_usize / reserve_segments) return error.KcpPoolTooLarge;
                const total_len = slot_size * reserve_segments;
                const memory = backing_allocator.rawAlloc(total_len, allocation_alignment, @returnAddress()) orelse {
                    return error.OutOfMemory;
                };
                errdefer backing_allocator.rawFree(memory[0..total_len], allocation_alignment, @returnAddress());

                blocks = memory[0..total_len];
                free_next = try backing_allocator.alloc(u32, reserve_segments);
                errdefer backing_allocator.free(free_next);

                for (free_next, 0..) |*next, i| {
                    next.* = if (i + 1 < reserve_segments) @intCast(i + 1) else invalid_index;
                }
            }

            return .{
                .backing_allocator = backing_allocator,
                .blocks = blocks,
                .free_next = free_next,
                .free_head = if (reserve_segments > 0) 0 else invalid_index,
                .segment_size = segment_size,
                .slot_size = slot_size,
                .available_segments = reserve_segments,
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.blocks.len > 0) {
                self.backing_allocator.rawFree(self.blocks, allocation_alignment, @returnAddress());
            }
            self.backing_allocator.free(self.free_next);
            self.* = undefined;
        }

        pub fn allocator(self: *Self) kcp.Allocator {
            return .{
                .ctx = self,
                .malloc_fn = malloc,
                .free_fn = free,
            };
        }

        pub fn snapshot(self: *Self) Snapshot {
            self.mutex.lock();
            defer self.mutex.unlock();
            return .{
                .segment_size = self.segment_size,
                .reserved_segments = self.free_next.len,
                .available_segments = self.available_segments,
                .pooled_allocs = self.pooled_allocs,
                .pooled_frees = self.pooled_frees,
                .fallback_allocs = self.fallback_allocs,
                .fallback_frees = self.fallback_frees,
                .allocation_failures = self.allocation_failures,
            };
        }

        fn malloc(ctx: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
            const self: *Self = @ptrCast(@alignCast(ctx orelse return null));
            if (size <= self.segment_size) {
                if (self.allocPooled()) |ptr| return ptr;
            }
            return self.allocFallback(size);
        }

        fn free(ctx: ?*anyopaque, ptr: ?*anyopaque) callconv(.c) void {
            const payload = ptr orelse return;
            const self: *Self = @ptrCast(@alignCast(ctx orelse return));
            const base_addr = @intFromPtr(payload) - @sizeOf(Header);
            const header: *Header = @ptrFromInt(base_addr);
            switch (header.tag) {
                pooled_tag => self.freePooled(header.index),
                fallback_tag => {
                    const memory: [*]u8 = @ptrFromInt(base_addr);
                    const total_len = header.total_len;
                    self.backing_allocator.rawFree(memory[0..total_len], allocation_alignment, @returnAddress());
                    self.mutex.lock();
                    self.fallback_frees += 1;
                    self.mutex.unlock();
                },
                else => @panic("kcp.SegmentPool.free received an unknown allocation"),
            }
        }

        fn allocPooled(self: *Self) ?*anyopaque {
            self.mutex.lock();
            defer self.mutex.unlock();

            const index = self.free_head;
            if (index == invalid_index) return null;
            self.free_head = self.free_next[index];
            self.available_segments -= 1;
            self.pooled_allocs += 1;

            const base_addr = @intFromPtr(self.blocks.ptr) + (@as(usize, index) * self.slot_size);
            const header: *Header = @ptrFromInt(base_addr);
            header.* = .{
                .tag = pooled_tag,
                .index = index,
                .total_len = self.slot_size,
            };
            return @ptrFromInt(base_addr + @sizeOf(Header));
        }

        fn allocFallback(self: *Self, size: usize) ?*anyopaque {
            if (size > max_usize - @sizeOf(Header)) {
                self.recordFailure();
                return null;
            }
            const total_len = @sizeOf(Header) + size;
            const memory = self.backing_allocator.rawAlloc(total_len, allocation_alignment, @returnAddress()) orelse {
                self.recordFailure();
                return null;
            };
            const header: *Header = @ptrCast(@alignCast(memory));
            header.* = .{
                .tag = fallback_tag,
                .index = invalid_index,
                .total_len = total_len,
            };
            self.mutex.lock();
            self.fallback_allocs += 1;
            self.mutex.unlock();
            return @ptrFromInt(@intFromPtr(memory) + @sizeOf(Header));
        }

        fn freePooled(self: *Self, index: u32) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            std.debug.assert(index < self.free_next.len);
            self.free_next[index] = self.free_head;
            self.free_head = index;
            self.available_segments += 1;
            self.pooled_frees += 1;
        }

        fn recordFailure(self: *Self) void {
            self.mutex.lock();
            self.allocation_failures += 1;
            self.mutex.unlock();
        }
    };
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    return glib.testing.TestRunner.fromFn(grt.std, 256 * 1024, struct {
        fn run(_: *glib.testing.T, allocator: grt.std.mem.Allocator) !void {
            const std = grt.std;
            const SegmentPool = make(grt);

            var pool = try SegmentPool.init(allocator, 1376, 2);
            defer pool.deinit();

            const kcp_allocator = pool.allocator();
            const first = kcp_allocator.malloc_fn.?(kcp_allocator.ctx, pool.segment_size) orelse {
                return error.ExpectedFirstPooledAllocation;
            };
            const second = kcp_allocator.malloc_fn.?(kcp_allocator.ctx, pool.segment_size) orelse {
                return error.ExpectedSecondPooledAllocation;
            };
            var snap = pool.snapshot();
            try std.testing.expectEqual(@as(usize, 2), snap.pooled_allocs);
            try std.testing.expectEqual(@as(usize, 0), snap.available_segments);

            kcp_allocator.free_fn.?(kcp_allocator.ctx, first);
            kcp_allocator.free_fn.?(kcp_allocator.ctx, second);
            snap = pool.snapshot();
            try std.testing.expectEqual(@as(usize, 2), snap.pooled_frees);
            try std.testing.expectEqual(@as(usize, 2), snap.available_segments);

            const reused = kcp_allocator.malloc_fn.?(kcp_allocator.ctx, pool.segment_size) orelse {
                return error.ExpectedReusedPooledAllocation;
            };
            try std.testing.expect(reused == second);
            kcp_allocator.free_fn.?(kcp_allocator.ctx, reused);

            const fallback = kcp_allocator.malloc_fn.?(kcp_allocator.ctx, pool.segment_size + 1) orelse {
                return error.ExpectedFallbackAllocation;
            };
            snap = pool.snapshot();
            try std.testing.expectEqual(@as(usize, 1), snap.fallback_allocs);
            kcp_allocator.free_fn.?(kcp_allocator.ctx, fallback);
            snap = pool.snapshot();
            try std.testing.expectEqual(@as(usize, 1), snap.fallback_frees);
        }
    }.run);
}
