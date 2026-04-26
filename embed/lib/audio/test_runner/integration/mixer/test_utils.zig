const glib = @import("glib");
pub fn waitUntilTrue(comptime grt: type, flag: *grt.std.atomic.Value(bool), comptime err_tag: anyerror) !void {
    const Thread = grt.std.Thread;

    var spins: usize = 0;
    while (!flag.load(.acquire)) : (spins += 1) {
        if (spins == 10_000) return err_tag;
        if (spins % 128 == 0) {
            Thread.sleep(100_000);
        } else {
            Thread.yield() catch {};
        }
    }
}

fn allocatorAlignment(comptime grt: type) type {
    const alloc_ptr_type = @TypeOf(grt.std.testing.allocator.vtable.alloc);
    const alloc_fn_type = @typeInfo(alloc_ptr_type).pointer.child;
    return @typeInfo(alloc_fn_type).@"fn".params[2].type.?;
}

pub fn CountingAllocatorType(comptime grt: type) type {
    const Allocator = glib.std.mem.Allocator;
    const Alignment = allocatorAlignment(grt);

    return struct {
        backing: Allocator,
        alloc_count: usize = 0,
        resize_count: usize = 0,
        remap_count: usize = 0,

        const Self = @This();

        pub const Snapshot = struct {
            alloc_count: usize,
            resize_count: usize,
            remap_count: usize,
        };

        pub fn init(backing: Allocator) Self {
            return .{ .backing = backing };
        }

        pub fn allocator(self: *Self) Allocator {
            return .{
                .ptr = self,
                .vtable = &vtable,
            };
        }

        pub fn snapshot(self: *Self) Snapshot {
            return .{
                .alloc_count = self.alloc_count,
                .resize_count = self.resize_count,
                .remap_count = self.remap_count,
            };
        }

        fn alloc(ptr: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.alloc_count += 1;
            return self.backing.rawAlloc(len, alignment, ret_addr);
        }

        fn resize(ptr: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.resize_count += 1;
            return self.backing.rawResize(memory, alignment, new_len, ret_addr);
        }

        fn remap(ptr: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.remap_count += 1;
            return self.backing.rawRemap(memory, alignment, new_len, ret_addr);
        }

        fn free(ptr: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.backing.rawFree(memory, alignment, ret_addr);
        }

        const vtable: Allocator.VTable = .{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        };
    };
}
