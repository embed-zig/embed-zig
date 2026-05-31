const glib = @import("glib");

pub const Caps = enum {
    internal,
    spiram,
    internal_8bit,
    spiram_8bit,
    internal_dma_8bit,
};

pub const Alignment = enum {
    natural,
    align_u32,
};

pub const Padding = enum {
    none,
    freertos_stack,
};

pub const Options = struct {
    caps: Caps,
    alignment: Alignment = .natural,
    padding: Padding = .none,
};

pub fn Allocator(comptime options: Options) glib.std.mem.Allocator {
    return allocatorFromCapsProvider(options);
}

extern fn espz_heap_align_freertos_stack_size_bytes(size: u32) u32;
extern fn espz_heap_caps_malloc(size: usize, caps: u32) ?*anyopaque;
extern fn espz_heap_caps_free(ptr: ?*anyopaque) void;

extern const espz_heap_cap_8bit: u32;
extern const espz_heap_cap_dma: u32;
extern const espz_heap_cap_spiram: u32;
extern const espz_heap_cap_internal: u32;

fn allocatorFromCapsProvider(comptime options: Options) glib.std.mem.Allocator {
    const Impl = struct {
        fn alloc(_: *anyopaque, len: usize, requested_alignment: glib.std.mem.Alignment, ret_addr: usize) ?[*]u8 {
            _ = ret_addr;

            const effective_alignment = requiredAlignmentBytes(requested_alignment, options.alignment);
            const effective_len = paddedSize(len, options.padding) orelse return null;
            if (effective_len == 0) {
                return @ptrFromInt(effective_alignment);
            }

            return heapCapsAlloc(effective_len, effective_alignment, resolveCaps(options.caps));
        }

        fn resize(
            _: *anyopaque,
            memory: []u8,
            requested_alignment: glib.std.mem.Alignment,
            new_len: usize,
            ret_addr: usize,
        ) bool {
            _ = requested_alignment;
            _ = ret_addr;
            return new_len <= memory.len;
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
            _ = ret_addr;
            if (memory.len == 0) return;
            heapCapsFree(memory.ptr, requiredAlignmentBytes(requested_alignment, options.alignment));
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

fn heapCapsMallocAlignmentBytes() usize {
    return @alignOf(usize);
}

fn heapCapsAlloc(len: usize, alignment: usize, caps: u32) ?[*]u8 {
    if (alignment <= heapCapsMallocAlignmentBytes()) {
        const raw = espz_heap_caps_malloc(len, caps) orelse return null;
        return @ptrCast(raw);
    }

    const with_header, const header_overflow = @addWithOverflow(len, @sizeOf(usize));
    if (header_overflow != 0) return null;
    const total_len, const alignment_overflow = @addWithOverflow(with_header, alignment - 1);
    if (alignment_overflow != 0) return null;

    const raw = espz_heap_caps_malloc(total_len, caps) orelse return null;
    const payload_addr, const payload_overflow = @addWithOverflow(@intFromPtr(raw), @sizeOf(usize));
    if (payload_overflow != 0) {
        espz_heap_caps_free(raw);
        return null;
    }

    const aligned_addr = glib.std.mem.alignForward(usize, payload_addr, alignment);
    const raw_addr_slot: *usize = @ptrFromInt(aligned_addr - @sizeOf(usize));
    raw_addr_slot.* = @intFromPtr(raw);
    return @ptrFromInt(aligned_addr);
}

fn heapCapsFree(ptr: [*]u8, alignment: usize) void {
    if (alignment <= heapCapsMallocAlignmentBytes()) {
        espz_heap_caps_free(ptr);
        return;
    }

    const raw_addr_slot: *usize = @ptrFromInt(@intFromPtr(ptr) - @sizeOf(usize));
    espz_heap_caps_free(@ptrFromInt(raw_addr_slot.*));
}

fn paddedSize(len: usize, comptime padding: Padding) ?usize {
    return switch (padding) {
        .none => len,
        .freertos_stack => blk: {
            if (len == 0) break :blk 0;
            if (len > glib.std.math.maxInt(u32)) break :blk null;
            const aligned = espz_heap_align_freertos_stack_size_bytes(@intCast(len));
            if (aligned == 0) break :blk null;
            break :blk aligned;
        },
    };
}

fn resolveCaps(comptime caps: Caps) u32 {
    return switch (caps) {
        .internal => espz_heap_cap_internal,
        .spiram => espz_heap_cap_spiram,
        .internal_8bit => espz_heap_cap_internal | espz_heap_cap_8bit,
        .spiram_8bit => espz_heap_cap_spiram | espz_heap_cap_8bit,
        .internal_dma_8bit => espz_heap_cap_internal | espz_heap_cap_dma | espz_heap_cap_8bit,
    };
}
