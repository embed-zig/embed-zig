//! Chunk — BLE xfer chunk encoding and bitmask utilities.

const embed = @import("embed");
const testing_api = @import("testing");

/// Maximum number of chunks supported by the 12-bit header fields.
pub const max_chunks: u16 = 4095;

/// Chunk header size in bytes.
pub const header_size: usize = 3;

/// ATT protocol overhead (opcode + handle).
pub const att_overhead: usize = 3;

/// Total overhead per transmitted chunk.
pub const chunk_overhead: usize = header_size + att_overhead;

/// Maximum BLE ATT_MTU supported by the protocol.
pub const max_mtu: usize = 517;

/// Maximum tracking bitmask size in bytes.
pub const max_mask_bytes: usize = (max_chunks + 7) / 8;

/// Start marker sent by the client to request a `read_x` transfer.
pub const read_start_magic = [4]u8{ 0xFF, 0xFF, 0x00, 0x01 };

/// Start marker sent by the client to begin a `write_x` transfer.
pub const write_start_magic = [4]u8{ 0xFF, 0xFF, 0x00, 0x02 };

/// ACK marker sent by the receiver once all chunks arrive.
pub const ack_signal = [2]u8{ 0xFF, 0xFF };

pub const Header = struct {
    total: u16,
    seq: u16,

    pub fn encode(self: Header) [header_size]u8 {
        return .{
            @intCast((self.total >> 4) & 0xFF),
            @intCast(((self.total & 0xF) << 4) | ((self.seq >> 8) & 0xF)),
            @intCast(self.seq & 0xFF),
        };
    }

    pub fn decode(bytes: []const u8) Header {
        return .{
            .total = @as(u16, bytes[0]) << 4 | @as(u16, bytes[1]) >> 4,
            .seq = @as(u16, bytes[1] & 0xF) << 8 | @as(u16, bytes[2]),
        };
    }

    pub fn validate(self: Header) error{InvalidHeader}!void {
        if (self.total == 0 or self.total > max_chunks) return error.InvalidHeader;
        if (self.seq == 0 or self.seq > self.total) return error.InvalidHeader;
    }
};

pub fn isReadStartMagic(data: []const u8) bool {
    return data.len >= read_start_magic.len and embed.mem.eql(u8, data[0..read_start_magic.len], &read_start_magic);
}

pub fn isWriteStartMagic(data: []const u8) bool {
    return data.len >= write_start_magic.len and embed.mem.eql(u8, data[0..write_start_magic.len], &write_start_magic);
}

pub fn isAck(data: []const u8) bool {
    return data.len >= ack_signal.len and data[0] == 0xFF and data[1] == 0xFF;
}

pub fn encodeLossList(seqs: []const u16, buf: []u8) []u8 {
    var offset: usize = 0;
    for (seqs) |seq| {
        if (offset + 2 > buf.len) break;
        buf[offset] = @intCast((seq >> 8) & 0xFF);
        buf[offset + 1] = @intCast(seq & 0xFF);
        offset += 2;
    }
    return buf[0..offset];
}

pub fn decodeLossList(data: []const u8, out: []u16) usize {
    var count: usize = 0;
    var offset: usize = 0;
    while (offset + 2 <= data.len and count < out.len) {
        out[count] = @as(u16, data[offset]) << 8 | @as(u16, data[offset + 1]);
        count += 1;
        offset += 2;
    }
    return count;
}

pub const Bitmask = struct {
    pub fn requiredBytes(total: u16) usize {
        return (@as(usize, total) + 7) / 8;
    }

    pub fn initClear(buf: []u8, total: u16) void {
        @memset(buf[0..requiredBytes(total)], 0);
    }

    pub fn initAllSet(buf: []u8, total: u16) void {
        const len = requiredBytes(total);
        @memset(buf[0..len], 0xFF);
        const remainder: u3 = @intCast(total % 8);
        if (remainder != 0) {
            buf[len - 1] = (@as(u8, 1) << remainder) - 1;
        }
    }

    pub fn set(buf: []u8, seq: u16) void {
        const idx = seq - 1;
        buf[idx / 8] |= @as(u8, 1) << @intCast(idx % 8);
    }

    pub fn clear(buf: []u8, seq: u16) void {
        const idx = seq - 1;
        buf[idx / 8] &= ~(@as(u8, 1) << @intCast(idx % 8));
    }

    pub fn isSet(buf: []const u8, seq: u16) bool {
        const idx = seq - 1;
        return (buf[idx / 8] & (@as(u8, 1) << @intCast(idx % 8))) != 0;
    }

    pub fn isComplete(buf: []const u8, total: u16) bool {
        const full_bytes: usize = @as(usize, total) / 8;
        for (buf[0..full_bytes]) |b| {
            if (b != 0xFF) return false;
        }
        const remainder: u3 = @intCast(total % 8);
        if (remainder != 0) {
            const expected: u8 = (@as(u8, 1) << remainder) - 1;
            if ((buf[full_bytes] & expected) != expected) return false;
        }
        return true;
    }

    pub fn collectMissing(buf: []const u8, total: u16, out: []u16) usize {
        var count: usize = 0;
        var seq: u16 = 1;
        while (seq <= total and count < out.len) : (seq += 1) {
            if (!isSet(buf, seq)) {
                out[count] = seq;
                count += 1;
            }
        }
        return count;
    }
};

pub fn dataChunkSize(mtu: u16) usize {
    if (mtu <= chunk_overhead) return 1;
    return @as(usize, mtu) - chunk_overhead;
}

pub fn chunksNeeded(data_len: usize, mtu: u16) usize {
    const dcs = dataChunkSize(mtu);
    if (data_len == 0) return 0;
    return (data_len + dcs - 1) / dcs;
}

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    const TestCase = struct {
        fn run() !void {
            const headers = [_]Header{
                .{ .total = 1, .seq = 1 },
                .{ .total = 100, .seq = 50 },
                .{ .total = 256, .seq = 128 },
                .{ .total = 4095, .seq = 1 },
                .{ .total = 4095, .seq = 4095 },
                .{ .total = 0xABC, .seq = 0x123 },
            };
            for (headers) |header| {
                const encoded = header.encode();
                const decoded = Header.decode(&encoded);
                try lib.testing.expectEqual(header.total, decoded.total);
                try lib.testing.expectEqual(header.seq, decoded.seq);
            }

            try (Header{ .total = 1, .seq = 1 }).validate();
            try (Header{ .total = 4095, .seq = 4095 }).validate();
            try lib.testing.expectError(error.InvalidHeader, (Header{ .total = 0, .seq = 1 }).validate());
            try lib.testing.expectError(error.InvalidHeader, (Header{ .total = 1, .seq = 0 }).validate());
            try lib.testing.expectError(error.InvalidHeader, (Header{ .total = 1, .seq = 2 }).validate());
            try lib.testing.expectError(error.InvalidHeader, (Header{ .total = 4096, .seq = 1 }).validate());

            try lib.testing.expect(isReadStartMagic(&read_start_magic));
            try lib.testing.expect(isWriteStartMagic(&write_start_magic));
            try lib.testing.expect(!isReadStartMagic(&write_start_magic));
            try lib.testing.expect(!isWriteStartMagic(&read_start_magic));
            try lib.testing.expect(isAck(&ack_signal));
            try lib.testing.expect(isAck(&[_]u8{ 0xFF, 0xFF, 0x00 }));
            try lib.testing.expect(!isAck(&[_]u8{0xFF}));

            const seqs = [_]u16{ 1, 42, 4095 };
            var loss_buf: [6]u8 = undefined;
            const encoded_loss = encodeLossList(&seqs, &loss_buf);
            try lib.testing.expectEqual(@as(usize, 6), encoded_loss.len);

            var decoded: [3]u16 = undefined;
            const decoded_count = decodeLossList(encoded_loss, &decoded);
            try lib.testing.expectEqual(@as(usize, 3), decoded_count);
            try lib.testing.expectEqualSlices(u16, &seqs, decoded[0..decoded_count]);

            var short_buf: [4]u8 = undefined;
            const truncated = encodeLossList(&seqs, &short_buf);
            try lib.testing.expectEqual(@as(usize, 4), truncated.len);

            var truncated_out: [2]u16 = undefined;
            const truncated_count = decodeLossList(truncated, &truncated_out);
            try lib.testing.expectEqual(@as(usize, 2), truncated_count);
            try lib.testing.expectEqual(@as(u16, 1), truncated_out[0]);
            try lib.testing.expectEqual(@as(u16, 42), truncated_out[1]);

            var mask_buf: [2]u8 = undefined;
            Bitmask.initClear(&mask_buf, 10);
            try lib.testing.expectEqual(@as(usize, 2), Bitmask.requiredBytes(10));
            try lib.testing.expect(!Bitmask.isSet(&mask_buf, 1));
            try lib.testing.expect(!Bitmask.isComplete(&mask_buf, 10));

            Bitmask.set(&mask_buf, 1);
            Bitmask.set(&mask_buf, 2);
            Bitmask.set(&mask_buf, 4);
            Bitmask.set(&mask_buf, 5);
            Bitmask.set(&mask_buf, 6);
            Bitmask.set(&mask_buf, 8);
            Bitmask.set(&mask_buf, 9);
            Bitmask.set(&mask_buf, 10);

            try lib.testing.expect(Bitmask.isSet(&mask_buf, 1));
            try lib.testing.expect(!Bitmask.isSet(&mask_buf, 3));
            try lib.testing.expect(!Bitmask.isSet(&mask_buf, 7));

            var missing: [10]u16 = undefined;
            const missing_count = Bitmask.collectMissing(&mask_buf, 10, &missing);
            try lib.testing.expectEqual(@as(usize, 2), missing_count);
            try lib.testing.expectEqual(@as(u16, 3), missing[0]);
            try lib.testing.expectEqual(@as(u16, 7), missing[1]);

            Bitmask.set(&mask_buf, 3);
            Bitmask.set(&mask_buf, 7);
            try lib.testing.expect(Bitmask.isComplete(&mask_buf, 10));
            Bitmask.clear(&mask_buf, 5);
            try lib.testing.expect(!Bitmask.isComplete(&mask_buf, 10));
            try lib.testing.expect(!Bitmask.isSet(&mask_buf, 5));

            var all_set: [2]u8 = undefined;
            Bitmask.initAllSet(&all_set, 10);
            try lib.testing.expectEqual(@as(u8, 0xFF), all_set[0]);
            try lib.testing.expectEqual(@as(u8, 0x03), all_set[1]);
            try lib.testing.expect(Bitmask.isComplete(&all_set, 10));

            var one_byte: [1]u8 = undefined;
            Bitmask.initAllSet(&one_byte, 3);
            try lib.testing.expectEqual(@as(u8, 0x07), one_byte[0]);

            try lib.testing.expectEqual(@as(usize, 241), dataChunkSize(247));
            try lib.testing.expectEqual(@as(usize, 24), dataChunkSize(30));
            try lib.testing.expectEqual(@as(usize, 1), dataChunkSize(7));
            try lib.testing.expectEqual(@as(usize, 1), dataChunkSize(6));
            try lib.testing.expectEqual(@as(usize, 1), dataChunkSize(1));
            try lib.testing.expectEqual(@as(usize, 0), chunksNeeded(0, 247));
            try lib.testing.expectEqual(@as(usize, 1), chunksNeeded(1, 247));
            try lib.testing.expectEqual(@as(usize, 4), chunksNeeded(964, 247));
            try lib.testing.expectEqual(@as(usize, 5), chunksNeeded(1000, 247));
            try lib.testing.expectEqual(@as(usize, 3), chunksNeeded(56, 30));
        }
    };
    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            TestCase.run() catch |err| {
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

