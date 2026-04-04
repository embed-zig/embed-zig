//! xfer.read — shared read-side transfer loop shape.
//!
//! This file only defines the top-level function shape for a future shared
//! xfer read loop. The concrete transport is supplied by the caller and must
//! provide one bidirectional session surface:
//! - `read(timeout_ms, out)` to wait for one inbound payload and copy it into `out`
//! - `write(data)` to emit one outbound control/data packet
//! - `deinit()` to release session resources

const att = @import("../att.zig");
const Chunk = @import("Chunk.zig");

pub const Config = struct {
    att_mtu: u16 = att.DEFAULT_MTU,
    timeout_ms: u32 = 1_000,
    max_timeout_retries: u8 = 5,
    topic: Chunk.Topic,
    metadata: []const u8 = &.{},
};

pub fn read(
    comptime lib: type,
    allocator: lib.mem.Allocator,
    transport: anytype,
    config: Config,
) ![]u8 {
    const TransportPtr = @TypeOf(transport);
    const Transport = switch (@typeInfo(TransportPtr)) {
        .pointer => |ptr| ptr.child,
        else => @compileError("xfer.read expects a transport pointer"),
    };

    comptime {
        _ = @as(*const fn (*Transport, u32, []u8) anyerror!usize, &Transport.read);
        _ = @as(*const fn (*Transport, []const u8) anyerror!usize, &Transport.write);
        _ = @as(*const fn (*Transport) void, &Transport.deinit);
    }

    defer transport.deinit();

    const request = try allocator.alloc(u8, Chunk.read_start_magic.len + Chunk.topic_size + config.metadata.len);
    defer allocator.free(request);

    @memcpy(request[0..Chunk.read_start_magic.len], &Chunk.read_start_magic);
    _ = Chunk.encodeReadStartMetadata(request[Chunk.read_start_magic.len..], config.topic, config.metadata);
    _ = try transport.write(request);

    const mtu = config.att_mtu;
    const dcs = Chunk.dataChunkSize(mtu);
    const max_chunk_msg = @as(usize, mtu) - Chunk.att_overhead;

    var rcvmask: [Chunk.max_mask_bytes]u8 = undefined;
    var chunk_buf: [Chunk.max_mtu]u8 = undefined;
    var out: ?[]u8 = null;
    errdefer if (out) |buf| allocator.free(buf);
    var total: u16 = 0;
    var last_chunk_len: usize = 0;
    var initialized = false;
    var timeout_count: u8 = 0;

    while (true) {
        const payload_len = transport.read(config.timeout_ms, &chunk_buf) catch |err| switch (err) {
            error.Timeout => {
                timeout_count += 1;
                if (timeout_count >= config.max_timeout_retries) return error.Timeout;
                if (!initialized) {
                    _ = try transport.write(request);
                    continue;
                }
                try sendMissingReadChunks(transport, rcvmask[0..Chunk.Bitmask.requiredBytes(total)], total, max_chunk_msg);
                continue;
            },
            else => return err,
        };

        timeout_count = 0;
        const payload = chunk_buf[0..payload_len];
        if (payload.len < Chunk.header_size) return error.InvalidPacket;
        if (payload.len > max_chunk_msg) return error.ChunkTooLarge;

        const hdr = Chunk.Header.decode(payload[0..Chunk.header_size]);
        try hdr.validate();

        if (!initialized) {
            total = hdr.total;
            Chunk.Bitmask.initClear(rcvmask[0..Chunk.Bitmask.requiredBytes(total)], total);
            out = try allocator.alloc(u8, @as(usize, total) * dcs);
            initialized = true;
        } else if (hdr.total != total) {
            return error.TotalMismatch;
        }

        const out_buf = out orelse unreachable;
        const body_len = payload.len - Chunk.header_size;
        const write_at = (@as(usize, hdr.seq) - 1) * dcs;
        if (write_at + body_len > out_buf.len) return error.NoSpaceLeft;
        @memcpy(out_buf[write_at .. write_at + body_len], payload[Chunk.header_size..]);

        if (hdr.seq == total) {
            last_chunk_len = body_len;
        }

        const mask_len = Chunk.Bitmask.requiredBytes(total);
        Chunk.Bitmask.set(rcvmask[0..mask_len], hdr.seq);
        if (Chunk.Bitmask.isComplete(rcvmask[0..mask_len], total)) {
            _ = try transport.write(&Chunk.ack_signal);
            const final_len = if (total == 0)
                0
            else
                (@as(usize, total) - 1) * dcs + last_chunk_len;
            return if (final_len == out_buf.len)
                out_buf
            else
                try allocator.realloc(out_buf, final_len);
        }
    }
}

fn sendMissingReadChunks(transport: anytype, rcvmask: []const u8, total: u16, max_chunk_msg: usize) !void {
    var send_buf: [Chunk.max_mtu]u8 = undefined;
    var loss_seqs: [Chunk.max_mtu / 2]u16 = undefined;
    const batch_cap = @max(@as(usize, 1), @min(loss_seqs.len, max_chunk_msg / 2));

    var loss_count: usize = 0;
    var seq: u16 = 1;
    while (seq <= total) : (seq += 1) {
        if (Chunk.Bitmask.isSet(rcvmask, seq)) continue;
        loss_seqs[loss_count] = seq;
        loss_count += 1;
        if (loss_count == batch_cap) {
            const encoded = Chunk.encodeLossList(loss_seqs[0..loss_count], &send_buf);
            _ = try transport.write(encoded);
            loss_count = 0;
        }
    }

    if (loss_count != 0) {
        const encoded = Chunk.encodeLossList(loss_seqs[0..loss_count], &send_buf);
        _ = try transport.write(encoded);
    }
}

test "bt/unit_tests/host/xfer/read/assembles_chunks_and_sends_ack" {
    const std = @import("std");
    const embed_std = @import("embed_std");

    const FakeTransport = struct {
        chunk1: [Chunk.header_size + 3]u8 = undefined,
        chunk2: [Chunk.header_size + 2]u8 = undefined,
        read_index: usize = 0,
        writes: [4][Chunk.max_mtu]u8 = undefined,
        write_lens: [4]usize = [_]usize{0} ** 4,
        write_count: usize = 0,
        deinited: bool = false,

        fn init() @This() {
            var self: @This() = .{};
            const hdr1 = (Chunk.Header{ .total = 2, .seq = 1 }).encode();
            const hdr2 = (Chunk.Header{ .total = 2, .seq = 2 }).encode();
            @memcpy(self.chunk1[0..Chunk.header_size], &hdr1);
            @memcpy(self.chunk1[Chunk.header_size..], "hel");
            @memcpy(self.chunk2[0..Chunk.header_size], &hdr2);
            @memcpy(self.chunk2[Chunk.header_size..], "lo");
            return self;
        }

        fn read(self: *@This(), _: u32, out: []u8) !usize {
            const payload = switch (self.read_index) {
                0 => self.chunk1[0..],
                1 => self.chunk2[0..],
                else => return error.Closed,
            };
            self.read_index += 1;
            @memcpy(out[0..payload.len], payload);
            return payload.len;
        }

        fn write(self: *@This(), data: []const u8) !usize {
            @memcpy(self.writes[self.write_count][0..data.len], data);
            self.write_lens[self.write_count] = data.len;
            self.write_count += 1;
            return data.len;
        }

        fn deinit(self: *@This()) void {
            self.deinited = true;
        }
    };

    var transport = FakeTransport.init();
    const payload = try read(embed_std.std, std.testing.allocator, &transport, .{
        .topic = 0x0102030405060708,
    });
    defer std.testing.allocator.free(payload);

    var expected_req: [Chunk.read_start_magic.len + Chunk.topic_size]u8 = undefined;
    @memcpy(expected_req[0..Chunk.read_start_magic.len], &Chunk.read_start_magic);
    _ = Chunk.encodeReadStartMetadata(expected_req[Chunk.read_start_magic.len..], 0x0102030405060708, &.{});

    try std.testing.expectEqual(@as(usize, 5), payload.len);
    try std.testing.expectEqualStrings("hello", payload);
    try std.testing.expect(transport.deinited);
    try std.testing.expectEqual(@as(usize, 2), transport.write_count);
    try std.testing.expectEqualSlices(u8, &expected_req, transport.writes[0][0..transport.write_lens[0]]);
    try std.testing.expectEqualSlices(u8, &Chunk.ack_signal, transport.writes[1][0..transport.write_lens[1]]);
}

test "bt/unit_tests/host/xfer/read/requests_missing_chunks_after_timeout" {
    const std = @import("std");
    const embed_std = @import("embed_std");

    const Step = union(enum) {
        payload: usize,
        timeout,
    };

    const script = [_]Step{
        .{ .payload = 0 },
        .timeout,
        .{ .payload = 1 },
    };

    const FakeTransport = struct {
        steps: [script.len]Step = script,
        chunk1: [Chunk.header_size + 3]u8 = undefined,
        chunk2: [Chunk.header_size + 2]u8 = undefined,
        step_index: usize = 0,
        writes: [4][Chunk.max_mtu]u8 = undefined,
        write_lens: [4]usize = [_]usize{0} ** 4,
        write_count: usize = 0,
        deinited: bool = false,

        fn init() @This() {
            var self: @This() = .{};
            const hdr1 = (Chunk.Header{ .total = 2, .seq = 1 }).encode();
            const hdr2 = (Chunk.Header{ .total = 2, .seq = 2 }).encode();
            @memcpy(self.chunk1[0..Chunk.header_size], &hdr1);
            @memcpy(self.chunk1[Chunk.header_size..], "hel");
            @memcpy(self.chunk2[0..Chunk.header_size], &hdr2);
            @memcpy(self.chunk2[Chunk.header_size..], "lo");
            return self;
        }

        fn read(self: *@This(), _: u32, out: []u8) !usize {
            const step = self.steps[self.step_index];
            self.step_index += 1;
            return switch (step) {
                .timeout => error.Timeout,
                .payload => |idx| blk: {
                    const payload = switch (idx) {
                        0 => self.chunk1[0..],
                        1 => self.chunk2[0..],
                        else => return error.Closed,
                    };
                    @memcpy(out[0..payload.len], payload);
                    break :blk payload.len;
                },
            };
        }

        fn write(self: *@This(), data: []const u8) !usize {
            @memcpy(self.writes[self.write_count][0..data.len], data);
            self.write_lens[self.write_count] = data.len;
            self.write_count += 1;
            return data.len;
        }

        fn deinit(self: *@This()) void {
            self.deinited = true;
        }
    };

    var transport = FakeTransport.init();
    const payload = try read(embed_std.std, std.testing.allocator, &transport, .{
        .topic = 0x0102030405060708,
    });
    defer std.testing.allocator.free(payload);

    var expected_loss: [Chunk.max_mtu]u8 = undefined;
    const expected = Chunk.encodeLossList(&.{2}, &expected_loss);
    var expected_req: [Chunk.read_start_magic.len + Chunk.topic_size]u8 = undefined;
    @memcpy(expected_req[0..Chunk.read_start_magic.len], &Chunk.read_start_magic);
    _ = Chunk.encodeReadStartMetadata(expected_req[Chunk.read_start_magic.len..], 0x0102030405060708, &.{});

    try std.testing.expectEqual(@as(usize, 5), payload.len);
    try std.testing.expectEqualStrings("hello", payload);
    try std.testing.expect(transport.deinited);
    try std.testing.expectEqual(@as(usize, 3), transport.write_count);
    try std.testing.expectEqualSlices(u8, &expected_req, transport.writes[0][0..transport.write_lens[0]]);
    try std.testing.expectEqualSlices(u8, expected, transport.writes[1][0..transport.write_lens[1]]);
    try std.testing.expectEqualSlices(u8, &Chunk.ack_signal, transport.writes[2][0..transport.write_lens[2]]);
}
