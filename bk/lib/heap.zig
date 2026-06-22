const glib = @import("glib");
const builtin = @import("builtin");
const std = @import("std");

pub const Source = enum {
    internal,
    psram,
};

pub const Alignment = enum {
    natural,
    align_u32,
};

pub const Options = struct {
    source: Source,
    alignment: Alignment = .natural,
};

pub const allocator = internal_allocator;
pub const internal_allocator = Allocator(.{ .source = .internal });
pub const psram_allocator = Allocator(.{ .source = .psram });

pub fn Allocator(comptime options: Options) glib.std.mem.Allocator {
    return allocatorFromSource(options);
}

extern fn os_malloc(size: usize) ?*anyopaque;
extern fn os_free(ptr: ?*anyopaque) void;
extern fn psram_malloc(size: usize) ?*anyopaque;

fn allocatorFromSource(comptime options: Options) glib.std.mem.Allocator {
    const Impl = struct {
        fn alloc(_: *anyopaque, len: usize, requested_alignment: glib.std.mem.Alignment, ret_addr: usize) ?[*]u8 {
            const alignment = requiredAlignmentBytes(requested_alignment, options.alignment);
            if (len == 0) {
                return @ptrFromInt(alignment);
            }

            return sourceAlloc(options.source, len, alignment, ret_addr);
        }

        fn resize(
            _: *anyopaque,
            memory: []u8,
            requested_alignment: glib.std.mem.Alignment,
            new_len: usize,
            ret_addr: usize,
        ) bool {
            _ = memory;
            _ = requested_alignment;
            _ = new_len;
            _ = ret_addr;
            return false;
        }

        fn remap(
            _: *anyopaque,
            memory: []u8,
            requested_alignment: glib.std.mem.Alignment,
            new_len: usize,
            ret_addr: usize,
        ) ?[*]u8 {
            _ = requested_alignment;
            _ = ret_addr;
            if (new_len <= memory.len) return memory.ptr;
            return null;
        }

        fn free(_: *anyopaque, memory: []u8, requested_alignment: glib.std.mem.Alignment, ret_addr: usize) void {
            if (memory.len == 0) return;
            sourceFree(memory, requiredAlignmentBytes(requested_alignment, options.alignment), ret_addr);
        }

        const vtable: glib.std.mem.Allocator.VTable = .{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        };
    };

    return .{
        .ptr = undefined,
        .vtable = &Impl.vtable,
    };
}

fn sourceAlloc(source: Source, len: usize, alignment: usize, ret_addr: usize) ?[*]u8 {
    if (builtin.is_test) {
        return std.heap.page_allocator.rawAlloc(len, std.mem.Alignment.fromByteUnits(alignment), ret_addr);
    }

    if (alignment <= mallocAlignmentBytes()) {
        const raw = switch (source) {
            .internal => os_malloc(len),
            .psram => psram_malloc(len),
        } orelse return null;
        return @ptrCast(raw);
    }

    const with_header, const header_overflow = @addWithOverflow(len, @sizeOf(usize));
    if (header_overflow != 0) return null;
    const total_len, const alignment_overflow = @addWithOverflow(with_header, alignment - 1);
    if (alignment_overflow != 0) return null;

    const raw = switch (source) {
        .internal => os_malloc(total_len),
        .psram => psram_malloc(total_len),
    } orelse return null;

    const payload_addr, const payload_overflow = @addWithOverflow(@intFromPtr(raw), @sizeOf(usize));
    if (payload_overflow != 0) {
        os_free(raw);
        return null;
    }

    const aligned_addr = glib.std.mem.alignForward(usize, payload_addr, alignment);
    const raw_addr_slot: *usize = @ptrFromInt(aligned_addr - @sizeOf(usize));
    raw_addr_slot.* = @intFromPtr(raw);
    return @ptrFromInt(aligned_addr);
}

fn sourceFree(memory: []u8, alignment: usize, ret_addr: usize) void {
    if (builtin.is_test) {
        std.heap.page_allocator.rawFree(memory, std.mem.Alignment.fromByteUnits(alignment), ret_addr);
        return;
    }

    if (alignment <= mallocAlignmentBytes()) {
        os_free(memory.ptr);
        return;
    }

    const raw_addr_slot: *usize = @ptrFromInt(@intFromPtr(memory.ptr) - @sizeOf(usize));
    os_free(@ptrFromInt(raw_addr_slot.*));
}

fn requiredAlignmentBytes(
    requested_alignment: glib.std.mem.Alignment,
    comptime alignment: Alignment,
) usize {
    const requested = requested_alignment.toByteUnits();
    const minimum = comptime minimumAlignmentBytes(alignment);
    return @max(requested, minimum);
}

fn minimumAlignmentBytes(comptime alignment: Alignment) usize {
    return switch (alignment) {
        .natural => 1,
        .align_u32 => @alignOf(u32),
    };
}

fn mallocAlignmentBytes() usize {
    return @alignOf(usize);
}
