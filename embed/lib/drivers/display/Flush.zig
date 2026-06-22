const glib = @import("glib");

const Rgb = @import("Rgb.zig");

pub const Error = error{
    OutOfBounds,
};

pub const Orientation = enum {
    normal,
    rotate_cw,
};

pub const Rgb565ByteOrder = enum {
    native,
    swapped,
};

pub const NativePixelFormat = enum {
    rgb565,
    rgb444_packed,
};

pub const Rect = struct {
    x: u16,
    y: u16,
    w: u16,
    h: u16,
};

pub const Config = struct {
    native_width: u16,
    native_height: u16,
    logical_width: u16,
    logical_height: u16,
    max_flush_rows: u16,
    rgb565_byte_order: Rgb565ByteOrder,
    orientation: Orientation = .normal,
};

pub fn width(config: Config) u16 {
    return config.logical_width;
}

pub fn height(config: Config) u16 {
    return config.logical_height;
}

pub fn maxChunkPixels(config: Config) usize {
    return @as(usize, config.logical_width) * @as(usize, normalizedRows(config));
}

pub fn maxChunkBytes(config: Config, pixel_format: NativePixelFormat) usize {
    const pixels = maxChunkPixels(config);
    return switch (pixel_format) {
        .rgb565 => pixels * @sizeOf(u16),
        .rgb444_packed => packedRgb444ByteLen(pixels),
    };
}

pub fn validate(
    config: Config,
    x: u16,
    y: u16,
    w: u16,
    h: u16,
    pixels: []const Rgb,
) Error!void {
    const x_end = @as(u32, x) + @as(u32, w);
    const y_end = @as(u32, y) + @as(u32, h);
    const pixel_count = @as(usize, w) * @as(usize, h);
    if (x_end > config.logical_width or y_end > config.logical_height or pixels.len < pixel_count) {
        return error.OutOfBounds;
    }
}

pub fn chunkRows(config: Config, h: u16, row: u16) u16 {
    const max_rows = normalizedRows(config);
    const remaining = h - row;
    return if (remaining > max_rows) max_rows else remaining;
}

pub fn encodeChunk(
    config: Config,
    dst: []u16,
    src: []const Rgb,
    src_offset: usize,
    w: u16,
    rows: u16,
) Error![]const u16 {
    const count = @as(usize, w) * @as(usize, rows);
    if (dst.len < count or src.len < src_offset + count) return error.OutOfBounds;

    switch (config.orientation) {
        .normal => {
            for (0..count) |index| {
                dst[index] = encodeForBus(src[src_offset + index], config.rgb565_byte_order);
            }
        },
        .rotate_cw => {
            for (0..w) |dst_y| {
                const src_x = @as(usize, w) - 1 - dst_y;
                for (0..rows) |dst_x| {
                    const src_y = dst_x;
                    dst[dst_y * @as(usize, rows) + dst_x] = encodeForBus(
                        src[src_offset + src_y * @as(usize, w) + src_x],
                        config.rgb565_byte_order,
                    );
                }
            }
        },
    }

    return dst[0..count];
}

pub fn encodeChunkBytes(
    config: Config,
    pixel_format: NativePixelFormat,
    dst: []u8,
    src: []const Rgb,
    src_offset: usize,
    w: u16,
    rows: u16,
) Error![]const u8 {
    return switch (pixel_format) {
        .rgb565 => {
            const count = @as(usize, w) * @as(usize, rows);
            const byte_count = count * @sizeOf(u16);
            if (dst.len < byte_count or src.len < src_offset + count) return error.OutOfBounds;
            switch (config.orientation) {
                .normal => {
                    for (0..count) |index| {
                        writeNativeRgb565(dst, index, src[src_offset + index], config.rgb565_byte_order);
                    }
                },
                .rotate_cw => {
                    var out_index: usize = 0;
                    for (0..w) |dst_y| {
                        const src_x = @as(usize, w) - 1 - dst_y;
                        for (0..rows) |dst_x| {
                            const src_y = dst_x;
                            writeNativeRgb565(
                                dst,
                                out_index,
                                src[src_offset + src_y * @as(usize, w) + src_x],
                                config.rgb565_byte_order,
                            );
                            out_index += 1;
                        }
                    }
                },
            }
            return dst[0..byte_count];
        },
        .rgb444_packed => encodeChunkRgb444(config, dst, src, src_offset, w, rows),
    };
}

pub fn encodeChunkRgb444(
    config: Config,
    dst: []u8,
    src: []const Rgb,
    src_offset: usize,
    w: u16,
    rows: u16,
) Error![]const u8 {
    const count = @as(usize, w) * @as(usize, rows);
    const byte_count = packedRgb444ByteLen(count);
    if (dst.len < byte_count or src.len < src_offset + count) return error.OutOfBounds;

    var out_index: usize = 0;
    var pending_low_nibble: ?u4 = null;

    switch (config.orientation) {
        .normal => {
            for (0..count) |index| {
                packRgb444Nibbles(dst, &out_index, &pending_low_nibble, src[src_offset + index]);
            }
        },
        .rotate_cw => {
            for (0..w) |dst_y| {
                const src_x = @as(usize, w) - 1 - dst_y;
                for (0..rows) |dst_x| {
                    const src_y = dst_x;
                    packRgb444Nibbles(
                        dst,
                        &out_index,
                        &pending_low_nibble,
                        src[src_offset + src_y * @as(usize, w) + src_x],
                    );
                }
            }
        },
    }
    if (pending_low_nibble) |high| {
        dst[out_index] = @as(u8, high) << 4;
        out_index += 1;
    }
    return dst[0..out_index];
}

pub fn nativeArea(config: Config, x: u16, y: u16, w: u16, row: u16, rows: u16) Rect {
    return switch (config.orientation) {
        .normal => .{
            .x = x,
            .y = y + row,
            .w = w,
            .h = rows,
        },
        .rotate_cw => .{
            .x = y + row,
            .y = config.native_height - x - w,
            .w = rows,
            .h = w,
        },
    };
}

fn normalizedRows(config: Config) u16 {
    return if (config.max_flush_rows == 0) 1 else config.max_flush_rows;
}

fn encodeForBus(color: Rgb, byte_order: Rgb565ByteOrder) u16 {
    const value = color.encode565();
    return switch (byte_order) {
        .native => value,
        .swapped => swap565(value),
    };
}

fn swap565(value: u16) u16 {
    return (value << 8) | (value >> 8);
}

fn writeNativeRgb565(dst: []u8, index: usize, color: Rgb, byte_order: Rgb565ByteOrder) void {
    const value = encodeForBus(color, byte_order);
    const offset = index * @sizeOf(u16);
    dst[offset] = @intCast(value & 0x00ff);
    dst[offset + 1] = @intCast(value >> 8);
}

fn packedRgb444ByteLen(pixel_count: usize) usize {
    return (pixel_count * 3 + 1) / 2;
}

fn packRgb444Nibbles(dst: []u8, out_index: *usize, pending_low_nibble: *?u4, color: Rgb) void {
    packNibble(dst, out_index, pending_low_nibble, @intCast(color.r >> 4));
    packNibble(dst, out_index, pending_low_nibble, @intCast(color.g >> 4));
    packNibble(dst, out_index, pending_low_nibble, @intCast(color.b >> 4));
}

fn packNibble(dst: []u8, out_index: *usize, pending_low_nibble: *?u4, nibble: u4) void {
    if (pending_low_nibble.*) |high| {
        dst[out_index.*] = (@as(u8, high) << 4) | @as(u8, nibble);
        out_index.* += 1;
        pending_low_nibble.* = null;
    } else {
        pending_low_nibble.* = nibble;
    }
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn validatesLogicalBoundsAndPixelCount() !void {
            const config = testConfig(.normal, .native);
            const pixels = [_]Rgb{rgb(255, 0, 0)} ** 4;

            try validate(config, 0, 0, 2, 2, &pixels);
            try grt.std.testing.expectError(error.OutOfBounds, validate(config, 2, 0, 2, 2, &pixels));
            try grt.std.testing.expectError(error.OutOfBounds, validate(config, 0, 0, 2, 2, pixels[0..3]));
        }

        fn encodesNormalRgb565Chunks() !void {
            const config = testConfig(.normal, .native);
            const pixels = [_]Rgb{
                rgb(255, 0, 0),
                rgb(0, 255, 0),
                rgb(0, 0, 255),
                rgb(255, 255, 255),
            };
            var out: [4]u16 = undefined;

            const encoded = try encodeChunk(config, &out, &pixels, 0, 2, 2);

            try grt.std.testing.expectEqualSlices(u16, &.{ 0xf800, 0x07e0, 0x001f, 0xffff }, encoded);
        }

        fn appliesSwappedRgb565ByteOrder() !void {
            const config = testConfig(.normal, .swapped);
            const pixels = [_]Rgb{rgb(255, 0, 0)};
            var out: [1]u16 = undefined;

            const encoded = try encodeChunk(config, &out, &pixels, 0, 1, 1);

            try grt.std.testing.expectEqual(@as(u16, 0x00f8), encoded[0]);
        }

        fn encodesPackedRgb444Chunks() !void {
            const config = testConfig(.normal, .native);
            const pixels = [_]Rgb{
                rgb(255, 0, 0),
                rgb(0, 255, 0),
                rgb(0, 0, 255),
            };
            var out: [5]u8 = undefined;

            const encoded = try encodeChunkRgb444(config, &out, &pixels, 0, 3, 1);

            try grt.std.testing.expectEqualSlices(u8, &.{ 0xf0, 0x00, 0xf0, 0x00, 0xf0 }, encoded);
        }

        fn rotatesChunksClockwiseAndMapsNativeArea() !void {
            const config = testConfig(.rotate_cw, .native);
            const pixels = [_]Rgb{
                rgb(255, 0, 0),
                rgb(0, 255, 0),
                rgb(0, 0, 255),
                rgb(255, 255, 255),
                rgb(1, 2, 3),
                rgb(4, 5, 6),
            };
            var out: [6]u16 = undefined;

            const encoded = try encodeChunk(config, &out, &pixels, 0, 3, 2);
            const area = nativeArea(config, 1, 2, 3, 0, 2);

            try grt.std.testing.expectEqualSlices(
                u16,
                &.{ rgb(0, 0, 255).encode565(), rgb(4, 5, 6).encode565(), rgb(0, 255, 0).encode565(), rgb(1, 2, 3).encode565(), rgb(255, 0, 0).encode565(), rgb(255, 255, 255).encode565() },
                encoded,
            );
            try grt.std.testing.expectEqual(@as(u16, 2), area.x);
            try grt.std.testing.expectEqual(@as(u16, 236), area.y);
            try grt.std.testing.expectEqual(@as(u16, 2), area.w);
            try grt.std.testing.expectEqual(@as(u16, 3), area.h);
        }

        fn clampsZeroMaxRowsToOneRow() !void {
            const config = Config{
                .native_width = 320,
                .native_height = 240,
                .logical_width = 4,
                .logical_height = 3,
                .max_flush_rows = 0,
                .rgb565_byte_order = .native,
            };

            try grt.std.testing.expectEqual(@as(usize, 4), maxChunkPixels(config));
            try grt.std.testing.expectEqual(@as(u16, 1), chunkRows(config, 3, 0));
            try grt.std.testing.expectEqual(@as(usize, 8), maxChunkBytes(config, .rgb565));
            try grt.std.testing.expectEqual(@as(usize, 6), maxChunkBytes(config, .rgb444_packed));
        }

        fn testConfig(orientation: Orientation, byte_order: Rgb565ByteOrder) Config {
            return .{
                .native_width = 320,
                .native_height = 240,
                .logical_width = 3,
                .logical_height = 2,
                .max_flush_rows = 2,
                .rgb565_byte_order = byte_order,
                .orientation = orientation,
            };
        }

        fn rgb(r: u8, g: u8, b: u8) Rgb {
            return Rgb.init(r, g, b);
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            TestCase.validatesLogicalBoundsAndPixelCount() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.encodesNormalRgb565Chunks() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.appliesSwappedRgb565ByteOrder() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.encodesPackedRgb444Chunks() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.rotatesChunksClockwiseAndMapsNativeArea() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.clampsZeroMaxRowsToOneRow() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: glib.std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return glib.testing.TestRunner.make(Runner).new(&Holder.runner);
}
