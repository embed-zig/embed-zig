//! `audio/ogg/PackBuffer.zig` owns the pure Zig rewrite of upstream
//! `oggpack_buffer` and the `oggpack_*` / `oggpackB_*` bit-packing routines.

const stdz = @import("stdz");
const testing_api = @import("testing");

const Self = @This();

const buffer_increment: usize = 256;

const Direction = enum {
    lsb,
    msb,
};

const masks = [33]u32{
    0x00000000, 0x00000001, 0x00000003, 0x00000007, 0x0000000f, 0x0000001f,
    0x0000003f, 0x0000007f, 0x000000ff, 0x000001ff, 0x000003ff, 0x000007ff,
    0x00000fff, 0x00001fff, 0x00003fff, 0x00007fff, 0x0000ffff, 0x0001ffff,
    0x0003ffff, 0x0007ffff, 0x000fffff, 0x001fffff, 0x003fffff, 0x007fffff,
    0x00ffffff, 0x01ffffff, 0x03ffffff, 0x07ffffff, 0x0fffffff, 0x1fffffff,
    0x3fffffff, 0x7fffffff, 0xffffffff,
};

const masks_msb_tail = [9]u8{
    0x00, 0x80, 0xc0, 0xe0, 0xf0, 0xf8, 0xfc, 0xfe, 0xff,
};

allocator: ?stdz.mem.Allocator = null,
buffer: ?[]u8 = null,
storage: usize = 0,
end_byte: usize = 0,
end_bit: u8 = 0,
owns_buffer: bool = false,
valid: bool = false,

pub const InitWriteError = stdz.mem.Allocator.Error;

pub const WriteError = stdz.mem.Allocator.Error || error{
    InvalidState,
    InvalidBitCount,
    Overflow,
    SourceTooShort,
};

pub const AccessError = error{
    InvalidBitCount,
};

pub fn initWrite(allocator: stdz.mem.Allocator) InitWriteError!Self {
    const buffer = try allocator.alloc(u8, buffer_increment);
    @memset(buffer, 0);
    return .{
        .allocator = allocator,
        .buffer = buffer,
        .storage = buffer.len,
        .end_byte = 0,
        .end_bit = 0,
        .owns_buffer = true,
        .valid = true,
    };
}

pub fn initRead(buffer: []u8) Self {
    return .{
        .buffer = buffer,
        .storage = buffer.len,
        .end_byte = 0,
        .end_bit = 0,
        .owns_buffer = false,
        .valid = true,
    };
}

pub fn deinit(self: *Self) void {
    if (self.owns_buffer) {
        if (self.buffer) |buffer| {
            if (self.allocator) |allocator| allocator.free(buffer);
        }
    }
    self.* = .{};
}

pub fn writeCheck(self: *const Self) bool {
    return self.valid and self.buffer != null and self.storage != 0;
}

pub fn writeTrunc(self: *Self, bit_count: usize) void {
    self.writeTruncWithDirection(bit_count, .lsb);
}

pub fn writeTruncMsb(self: *Self, bit_count: usize) void {
    self.writeTruncWithDirection(bit_count, .msb);
}

pub fn write(self: *Self, value: u32, bit_count: usize) WriteError!void {
    try self.writeWithDirection(value, bit_count, .lsb);
}

pub fn writeMsb(self: *Self, value: u32, bit_count: usize) WriteError!void {
    try self.writeWithDirection(value, bit_count, .msb);
}

pub fn writeAlign(self: *Self) WriteError!void {
    try self.writeAlignWithDirection(.lsb);
}

pub fn writeAlignMsb(self: *Self) WriteError!void {
    try self.writeAlignWithDirection(.msb);
}

pub fn writeCopy(self: *Self, source: []const u8, bit_count: usize) WriteError!void {
    try self.writeCopyWithDirection(source, bit_count, .lsb);
}

pub fn writeCopyMsb(self: *Self, source: []const u8, bit_count: usize) WriteError!void {
    try self.writeCopyWithDirection(source, bit_count, .msb);
}

pub fn reset(self: *Self) void {
    if (!self.writeCheck()) return;
    self.end_byte = 0;
    self.end_bit = 0;
    self.buffer.?[0] = 0;
}

pub fn readInit(self: *Self, buffer: []u8) void {
    self.deinit();
    self.* = initRead(buffer);
}

pub fn look(self: *const Self, bit_count: usize) AccessError!?u32 {
    return self.lookWithDirection(bit_count, .lsb);
}

pub fn lookMsb(self: *const Self, bit_count: usize) AccessError!?u32 {
    return self.lookWithDirection(bit_count, .msb);
}

pub fn look1(self: *const Self) ?u1 {
    const buffer = self.buffer orelse return null;
    if (!self.valid or self.end_byte >= self.storage) return null;
    const shift: u3 = @intCast(self.end_bit);
    return @truncate((buffer[self.end_byte] >> shift) & 1);
}

pub fn look1Msb(self: *const Self) ?u1 {
    const buffer = self.buffer orelse return null;
    if (!self.valid or self.end_byte >= self.storage) return null;
    const shift: u3 = @intCast(7 - self.end_bit);
    return @truncate((buffer[self.end_byte] >> shift) & 1);
}

pub fn adv(self: *Self, bit_count: usize) void {
    self.advWithDirection(bit_count, .lsb);
}

pub fn advMsb(self: *Self, bit_count: usize) void {
    self.advWithDirection(bit_count, .msb);
}

pub fn adv1(self: *Self) void {
    if (!self.valid) return;
    self.end_bit += 1;
    if (self.end_bit > 7) {
        self.end_bit = 0;
        self.end_byte += 1;
    }
}

pub fn adv1Msb(self: *Self) void {
    self.adv1();
}

pub fn read(self: *Self, bit_count: usize) AccessError!?u32 {
    return self.readWithDirection(bit_count, .lsb);
}

pub fn readMsb(self: *Self, bit_count: usize) AccessError!?u32 {
    return self.readWithDirection(bit_count, .msb);
}

pub fn read1(self: *Self) ?u1 {
    if (!self.valid or self.buffer == null or self.end_byte >= self.storage) {
        self.invalidate();
        return null;
    }
    const shift: u3 = @intCast(self.end_bit);
    const ret: u1 = @truncate((self.buffer.?[self.end_byte] >> shift) & 1);
    self.adv1();
    return ret;
}

pub fn read1Msb(self: *Self) ?u1 {
    if (!self.valid or self.buffer == null or self.end_byte >= self.storage) {
        self.invalidate();
        return null;
    }
    const shift: u3 = @intCast(7 - self.end_bit);
    const ret: u1 = @truncate((self.buffer.?[self.end_byte] >> shift) & 1);
    self.adv1();
    return ret;
}

pub fn bytes(self: *const Self) usize {
    return self.end_byte + (self.end_bit + 7) / 8;
}

pub fn bits(self: *const Self) usize {
    return self.end_byte * 8 + self.end_bit;
}

pub fn getBuffer(self: *Self) ?[]u8 {
    return self.buffer;
}

fn writeTruncWithDirection(self: *Self, bit_count: usize, direction: Direction) void {
    if (!self.writeCheck()) return;

    const byte_index = bit_count / 8;
    const bit_index: u8 = @intCast(bit_count - byte_index * 8);
    const buffer = self.buffer.?;

    if (byte_index >= buffer.len) {
        self.invalidate();
        return;
    }

    self.end_byte = byte_index;
    self.end_bit = bit_index;

    switch (direction) {
        .lsb => buffer[self.end_byte] &= @truncate(masks[self.end_bit]),
        .msb => buffer[self.end_byte] &= masks_msb_tail[self.end_bit],
    }
}

fn writeWithDirection(self: *Self, value: u32, bit_count: usize, direction: Direction) WriteError!void {
    if (bit_count > 32) {
        self.deinit();
        return error.InvalidBitCount;
    }
    if (!self.writeCheck() or !self.owns_buffer) {
        return error.InvalidState;
    }

    if (self.end_byte + 4 >= self.storage) {
        try self.expandWriteBuffer(buffer_increment);
    }

    const masked_value = @as(u64, value) & masks[bit_count];
    const total_bits = bit_count + self.end_bit;
    const bit_shift: u6 = @intCast(self.end_bit);
    const shift_from_8: u6 = @intCast(8 - self.end_bit);
    const shift_from_16: u6 = @intCast(16 - self.end_bit);
    const shift_from_24: u6 = @intCast(24 - self.end_bit);
    const shift_from_32: u6 = @intCast(32 - self.end_bit);
    const msb_shift_24: u6 = @intCast(24 + self.end_bit);
    const msb_shift_16: u6 = @intCast(16 + self.end_bit);
    const msb_shift_8: u6 = @intCast(8 + self.end_bit);
    const buffer = self.buffer.?;
    const byte_index = self.end_byte;

    switch (direction) {
        .lsb => {
            buffer[byte_index] |= @truncate(masked_value << bit_shift);
            if (total_bits >= 8) {
                buffer[byte_index + 1] = @truncate(masked_value >> shift_from_8);
                if (total_bits >= 16) {
                    buffer[byte_index + 2] = @truncate(masked_value >> shift_from_16);
                    if (total_bits >= 24) {
                        buffer[byte_index + 3] = @truncate(masked_value >> shift_from_24);
                        if (total_bits >= 32) {
                            buffer[byte_index + 4] = if (self.end_bit != 0)
                                @truncate(masked_value >> shift_from_32)
                            else
                                0;
                        }
                    }
                }
            }
        },
        .msb => {
            const shift_to_msb: u6 = @intCast(32 - bit_count);
            const shifted = masked_value << shift_to_msb;
            buffer[byte_index] |= @truncate(shifted >> msb_shift_24);
            if (total_bits >= 8) {
                buffer[byte_index + 1] = @truncate(shifted >> msb_shift_16);
                if (total_bits >= 16) {
                    buffer[byte_index + 2] = @truncate(shifted >> msb_shift_8);
                    if (total_bits >= 24) {
                        buffer[byte_index + 3] = @truncate(shifted >> bit_shift);
                        if (total_bits >= 32) {
                            buffer[byte_index + 4] = if (self.end_bit != 0)
                                @truncate(shifted << shift_from_8)
                            else
                                0;
                        }
                    }
                }
            }
        },
    }

    self.end_byte += total_bits / 8;
    self.end_bit = @intCast(total_bits & 7);
}

fn writeAlignWithDirection(self: *Self, direction: Direction) WriteError!void {
    const bits_needed = 8 - self.end_bit;
    if (bits_needed < 8) switch (direction) {
        .lsb => try self.write(0, bits_needed),
        .msb => try self.writeMsb(0, bits_needed),
    };
}

fn writeCopyWithDirection(self: *Self, source: []const u8, bit_count: usize, direction: Direction) WriteError!void {
    if (!self.writeCheck() or !self.owns_buffer) return error.InvalidState;

    const whole_bytes = bit_count / 8;
    const partial_write_bytes = (self.end_bit + bit_count) / 8;

    if (whole_bytes > source.len or (bit_count > whole_bytes * 8 and whole_bytes >= source.len)) return error.SourceTooShort;

    try self.ensureWriteSpace(partial_write_bytes);

    if (self.end_bit != 0) {
        var i: usize = 0;
        while (i < whole_bytes) : (i += 1) {
            switch (direction) {
                .lsb => try self.write(source[i], 8),
                .msb => try self.writeMsb(source[i], 8),
            }
        }
    } else if (whole_bytes > 0) {
        const buffer = self.buffer.?;
        @memcpy(buffer[self.end_byte .. self.end_byte + whole_bytes], source[0..whole_bytes]);
        self.end_byte += whole_bytes;
        buffer[self.end_byte] = 0;
    }

    const trailing_bits = bit_count - whole_bytes * 8;
    if (trailing_bits > 0) {
        switch (direction) {
            .lsb => try self.write(source[whole_bytes], trailing_bits),
            .msb => try self.writeMsb(source[whole_bytes] >> @intCast(8 - trailing_bits), trailing_bits),
        }
    }
}

fn lookWithDirection(self: *const Self, bit_count: usize, direction: Direction) AccessError!?u32 {
    const buffer = self.buffer orelse return null;
    if (!self.valid) return null;
    const bit_shift_byte: u3 = @intCast(self.end_bit);
    const bit_shift: u6 = @intCast(self.end_bit);
    const shift_from_8: u6 = @intCast(8 - self.end_bit);
    const shift_from_16: u6 = @intCast(16 - self.end_bit);
    const shift_from_24: u6 = @intCast(24 - self.end_bit);
    const shift_from_32: u6 = @intCast(32 - self.end_bit);
    const msb_shift_24: u6 = @intCast(24 + self.end_bit);
    const msb_shift_16: u6 = @intCast(16 + self.end_bit);
    const msb_shift_8: u6 = @intCast(8 + self.end_bit);

    switch (direction) {
        .lsb => {
            if (bit_count > 32) return error.InvalidBitCount;

            const total_bits = bit_count + self.end_bit;
            if (self.end_byte + 4 >= self.storage) {
                const required_bytes = (total_bits + 7) / 8;
                if (required_bytes == 0) return 0;
                if (required_bytes > self.storage or self.end_byte > self.storage - required_bytes) return null;
            }

            var ret: u64 = buffer[self.end_byte] >> bit_shift_byte;
            if (total_bits > 8) {
                ret |= @as(u64, buffer[self.end_byte + 1]) << shift_from_8;
                if (total_bits > 16) {
                    ret |= @as(u64, buffer[self.end_byte + 2]) << shift_from_16;
                    if (total_bits > 24) {
                        ret |= @as(u64, buffer[self.end_byte + 3]) << shift_from_24;
                        if (total_bits > 32 and self.end_bit != 0) {
                            ret |= @as(u64, buffer[self.end_byte + 4]) << shift_from_32;
                        }
                    }
                }
            }
            return @intCast(ret & masks[bit_count]);
        },
        .msb => {
            if (bit_count > 32) return error.InvalidBitCount;

            const shift = 32 - bit_count;
            const total_bits = bit_count + self.end_bit;
            if (self.end_byte + 4 >= self.storage) {
                const required_bytes = (total_bits + 7) / 8;
                if (required_bytes == 0) return 0;
                if (required_bytes > self.storage or self.end_byte > self.storage - required_bytes) return null;
            }

            var ret: u64 = @as(u64, buffer[self.end_byte]) << msb_shift_24;
            if (total_bits > 8) {
                ret |= @as(u64, buffer[self.end_byte + 1]) << msb_shift_16;
                if (total_bits > 16) {
                    ret |= @as(u64, buffer[self.end_byte + 2]) << msb_shift_8;
                    if (total_bits > 24) {
                        ret |= @as(u64, buffer[self.end_byte + 3]) << bit_shift;
                        if (total_bits > 32 and self.end_bit != 0) {
                            ret |= @as(u64, buffer[self.end_byte + 4]) >> shift_from_8;
                        }
                    }
                }
            }

            return @intCast(((ret & 0xffffffff) >> @intCast(shift >> 1)) >> @intCast((shift + 1) >> 1));
        },
    }
}

fn advWithDirection(self: *Self, bit_count: usize, _: Direction) void {
    if (!self.valid) return;

    const total_bits = bit_count + self.end_bit;
    const required_bytes = (total_bits + 7) / 8;
    if (required_bytes > self.storage or self.end_byte > self.storage - required_bytes) {
        self.invalidate();
        return;
    }

    self.end_byte += total_bits / 8;
    self.end_bit = @intCast(total_bits & 7);
}

fn readWithDirection(self: *Self, bit_count: usize, direction: Direction) AccessError!?u32 {
    const value = try self.lookWithDirection(bit_count, direction);
    if (value == null) {
        self.invalidate();
        return null;
    }
    self.advWithDirection(bit_count, direction);
    return value;
}

fn ensureWriteSpace(self: *Self, partial_write_bytes: usize) WriteError!void {
    if (self.end_byte + partial_write_bytes < self.storage) return;

    const needed = checkedAdd(self.end_byte, partial_write_bytes) orelse {
        self.deinit();
        return error.Overflow;
    };

    const grown = checkedAdd(needed, buffer_increment) orelse {
        self.deinit();
        return error.Overflow;
    };

    try self.expandWriteBufferTo(grown);
}

fn expandWriteBuffer(self: *Self, extra: usize) WriteError!void {
    const new_size = checkedAdd(self.storage, extra) orelse {
        self.deinit();
        return error.Overflow;
    };
    try self.expandWriteBufferTo(new_size);
}

fn expandWriteBufferTo(self: *Self, new_size: usize) WriteError!void {
    if (!self.owns_buffer or self.allocator == null or self.buffer == null) return error.InvalidState;
    self.buffer = (try self.allocator.?.realloc(self.buffer.?, new_size));
    self.storage = self.buffer.?.len;
}

fn invalidate(self: *Self) void {
    self.valid = false;
    self.end_byte = self.storage;
    self.end_bit = 1;
}

fn checkedAdd(a: usize, b: usize) ?usize {
    const result = @addWithOverflow(a, b);
    if (result[1] != 0) return null;
    return result[0];
}

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    const TestCase = struct {
        fn testLsbWriteReadAndAlignRoundTrip(allocator: lib.mem.Allocator) !void {
            const testing = lib.testing;

            var pack = try initWrite(allocator);
            defer pack.deinit();

            try pack.write(0b10101, 5);
            try pack.write(0b11110000, 8);
            try pack.writeAlign();

            const bytes_used = pack.bytes();
            try testing.expectEqual(@as(usize, 2), bytes_used);

            var reader = initRead(pack.getBuffer().?[0..bytes_used]);
            try testing.expectEqual(@as(?u32, 0b10101), try reader.look(5));
            try testing.expectEqual(@as(?u32, 0b10101), try reader.read(5));
            try testing.expectEqual(@as(?u32, 0b11110000), try reader.read(8));
        }

        fn testMsbWriteReadAndAlignRoundTrip(allocator: lib.mem.Allocator) !void {
            const testing = lib.testing;

            var pack = try initWrite(allocator);
            defer pack.deinit();

            try pack.writeMsb(0b10101, 5);
            try pack.writeMsb(0b11001100, 8);
            try pack.writeAlignMsb();

            const bytes_used = pack.bytes();
            var reader = initRead(pack.getBuffer().?[0..bytes_used]);
            try testing.expectEqual(@as(?u32, 0b10101), try reader.lookMsb(5));
            try testing.expectEqual(@as(?u32, 0b10101), try reader.readMsb(5));
            try testing.expectEqual(@as(?u32, 0b11001100), try reader.readMsb(8));
        }

        fn testWriteCopyPreservesTrailingBits(allocator: lib.mem.Allocator) !void {
            const testing = lib.testing;

            var source = try initWrite(allocator);
            defer source.deinit();
            try source.write(0x5a, 8);
            try source.write(0xc3, 8);

            var dest = try initWrite(allocator);
            defer dest.deinit();
            try dest.writeCopy(source.getBuffer().?[0..source.bytes()], 13);

            var reader = initRead(dest.getBuffer().?[0..dest.bytes()]);
            try testing.expectEqual(@as(?u32, 0x5a), try reader.read(8));
            try testing.expectEqual(@as(?u32, 0x03), try reader.read(5));
        }

        fn testPastEndReadInvalidatesBuffer() !void {
            const testing = lib.testing;

            var buffer = [_]u8{0};
            var reader = initRead(buffer[0..]);
            var i: usize = 0;
            while (i < 8) : (i += 1) {
                try testing.expectEqual(@as(?u1, 0), reader.read1());
            }
            try testing.expectEqual(@as(?u1, null), reader.read1());
            try testing.expect(!reader.valid);
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;

            TestCase.testLsbWriteReadAndAlignRoundTrip(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.testMsbWriteReadAndAlignRoundTrip(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.testWriteCopyPreservesTrailingBits(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.testPastEndReadInvalidatesBuffer() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: lib.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}
