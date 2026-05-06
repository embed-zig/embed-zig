const glib = @import("glib");
const ogg = @import("embed").audio.ogg;
const opus = @import("opus");
const board = @import("board.zig");
const esp = @import("esp");

const mem = glib.std.mem;
const log = esp.grt.std.log.scoped(.opus_ogg);

const output_sample_rate = 16_000;

extern fn open(path: [*:0]const u8, flags: c_int) c_int;
extern fn read(fd: c_int, buf: [*]u8, count: usize) isize;
extern fn close(fd: c_int) c_int;

const read_chunk_len: usize = 4096;
const decode_allocator_len: usize = 128 * 1024;
const opus_max_frame_samples: usize = 5760;

var decode_allocator_storage: [decode_allocator_len]u8 align(16) = undefined;
var pcm_storage: [opus_max_frame_samples]i16 align(16) = undefined;

pub const PlayResult = enum {
    ended,
    next,
    previous,
    microphone,
};

pub const ControlResult = enum {
    none,
    next,
    previous,
    microphone,
};

pub fn play(path: [:0]const u8, pollControl: *const fn () ControlResult) !PlayResult {
    log.info("opening Ogg Opus track with POSIX read: {s}", .{path});

    const fd = open(path, 0);
    if (fd < 0) return error.TrackOpenFailed;
    defer _ = close(fd);

    var decode_allocator = FixedDecodeAllocator.init(decode_allocator_storage[0..]);
    const allocator = decode_allocator.allocator();

    var sync = ogg.Sync.init(allocator);
    defer sync.deinit();

    var stream: ?ogg.Stream = null;
    defer if (stream) |*s| s.deinit();

    var decoder: ?opus.Decoder = null;
    defer if (decoder) |*d| d.deinit(allocator);

    var header_count: u8 = 0;
    var eof = false;

    while (true) {
        while (true) {
            switch (try sync.pageOut()) {
                .page => |page| {
                    if (stream == null) {
                        stream = try ogg.Stream.init(allocator, try page.serialNo());
                    }
                    if (stream) |*active_stream| {
                        try active_stream.pageIn(&page);

                        while (true) {
                            switch (try active_stream.packetOut()) {
                                .packet => |packet| {
                                    const payload = packet.payload();
                                    if (header_count == 0) {
                                        const channels = try parseOpusHead(payload);
                                        if (channels != 1) return error.UnsupportedChannelCount;
                                        decoder = try opus.Decoder.init(allocator, output_sample_rate, channels);
                                        header_count += 1;
                                        continue;
                                    }
                                    if (header_count == 1) {
                                        try parseOpusTags(payload);
                                        header_count += 1;
                                        continue;
                                    }

                                    switch (pollControl()) {
                                        .none => {},
                                        .next => return .next,
                                        .previous => return .previous,
                                        .microphone => return .microphone,
                                    }
                                    if (decoder == null) return error.MissingOpusHead;
                                    const packet_samples = try opus.packetGetSamples(payload, output_sample_rate);
                                    if (packet_samples > pcm_storage.len) return error.OpusFrameTooLarge;
                                    const samples = if (decoder) |*active_decoder|
                                        try active_decoder.decode(payload, pcm_storage[0..], false)
                                    else
                                        unreachable;
                                    try board.writePcm(samples);
                                    switch (pollControl()) {
                                        .none => {},
                                        .next => return .next,
                                        .previous => return .previous,
                                        .microphone => return .microphone,
                                    }
                                },
                                .hole => return error.OggPacketHole,
                                .none => break,
                            }
                        }
                    }
                },
                .hole => return error.OggSyncHole,
                .need_more => break,
            }
        }

        if (eof) break;

        const buffer = try sync.buffer(read_chunk_len);
        const n = read(fd, buffer.ptr, buffer.len);
        if (n < 0) return error.TrackReadFailed;
        if (n == 0) {
            eof = true;
        }
        try sync.wrote(@intCast(n));
    }

    if (header_count < 2) return error.MissingOpusHeaders;
    return .ended;
}

fn parseOpusHead(payload: []const u8) !u8 {
    if (payload.len < 19) return error.InvalidOpusHead;
    if (!mem.eql(u8, payload[0..8], "OpusHead")) return error.InvalidOpusHead;
    if (payload[8] != 1) return error.UnsupportedOpusHeadVersion;
    return payload[9];
}

fn parseOpusTags(payload: []const u8) !void {
    if (payload.len < 8) return error.InvalidOpusTags;
    if (!mem.eql(u8, payload[0..8], "OpusTags")) return error.InvalidOpusTags;
}

const FixedDecodeAllocator = struct {
    buffer: []u8,
    used: usize = 0,

    const Self = @This();

    fn init(buffer: []u8) Self {
        return .{ .buffer = buffer };
    }

    fn allocator(self: *Self) mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    fn alloc(ptr: *anyopaque, len: usize, alignment: mem.Alignment, ret_addr: usize) ?[*]u8 {
        _ = ret_addr;
        const self: *Self = @ptrCast(@alignCast(ptr));
        const base = @intFromPtr(self.buffer.ptr);
        const start_addr = add(base, self.used) orelse return null;
        const aligned_addr = alignForward(start_addr, alignment.toByteUnits()) orelse return null;
        const offset = aligned_addr - base;
        const end = add(offset, len) orelse return null;
        if (end > self.buffer.len) return null;

        self.used = end;
        return self.buffer.ptr + offset;
    }

    fn resize(ptr: *anyopaque, memory: []u8, alignment: mem.Alignment, new_len: usize, ret_addr: usize) bool {
        _ = alignment;
        _ = ret_addr;
        const self: *Self = @ptrCast(@alignCast(ptr));
        if (!self.owns(memory)) return false;

        if (!self.isLast(memory)) {
            return new_len <= memory.len;
        }

        const memory_offset = self.offsetOf(memory);
        if (new_len <= memory.len) {
            self.used = memory_offset + new_len;
            return true;
        }

        const end = add(memory_offset, new_len) orelse return false;
        if (end > self.buffer.len) return false;

        self.used = end;
        return true;
    }

    fn remap(ptr: *anyopaque, memory: []u8, alignment: mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        if (!resize(ptr, memory, alignment, new_len, ret_addr)) return null;
        return memory.ptr;
    }

    fn free(ptr: *anyopaque, memory: []u8, alignment: mem.Alignment, ret_addr: usize) void {
        _ = alignment;
        _ = ret_addr;
        const self: *Self = @ptrCast(@alignCast(ptr));
        if (self.owns(memory) and self.isLast(memory)) {
            self.used = self.offsetOf(memory);
        }
    }

    fn owns(self: *const Self, memory: []u8) bool {
        const base = @intFromPtr(self.buffer.ptr);
        const start = @intFromPtr(memory.ptr);
        const end = add(start, memory.len) orelse return false;
        const buffer_end = add(base, self.buffer.len) orelse return false;
        return start >= base and end <= buffer_end;
    }

    fn isLast(self: *const Self, memory: []u8) bool {
        return self.offsetOf(memory) + memory.len == self.used;
    }

    fn offsetOf(self: *const Self, memory: []u8) usize {
        return @intFromPtr(memory.ptr) - @intFromPtr(self.buffer.ptr);
    }

    const vtable: mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };
};

fn alignForward(value: usize, alignment: usize) ?usize {
    const mask = alignment - 1;
    return (add(value, mask) orelse return null) & ~mask;
}

fn add(a: usize, b: usize) ?usize {
    if (a > ~@as(usize, 0) - b) return null;
    return a + b;
}
