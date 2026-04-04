//! xfer.write — shared write-side transfer loop shape.
//!
//! This file defines the top-level function shape for a shared xfer write loop.
//! The concrete transport is supplied by the caller and must provide one
//! bidirectional session surface:
//! - `read(timeout_ms, out)` to wait for one inbound control packet
//! - `write(data)` to emit control packets such as the write start marker
//! - `writeNoResp(data)` to emit one outbound data chunk without response
//! - `deinit()` to release session resources

const att = @import("../att.zig");
const Chunk = @import("Chunk.zig");

pub const Config = struct {
    att_mtu: u16 = att.DEFAULT_MTU,
    timeout_ms: u32 = 5_000,
    send_redundancy: u8 = 3,
    max_timeout_retries: u8 = 5,
};

pub fn write(comptime lib: type, allocator: lib.mem.Allocator, transport: anytype, data: []const u8, config: Config) !void {
    const TransportPtr = @TypeOf(transport);
    const Transport = switch (@typeInfo(TransportPtr)) {
        .pointer => |ptr| ptr.child,
        else => @compileError("xfer.write expects a transport pointer"),
    };

    comptime {
        _ = @as(*const fn (*Transport, u32, []u8) anyerror!usize, &Transport.read);
        _ = @as(*const fn (*Transport, []const u8) anyerror!usize, &Transport.write);
        _ = @as(*const fn (*Transport, []const u8) anyerror!usize, &Transport.writeNoResp);
        _ = @as(*const fn (*Transport) void, &Transport.deinit);
    }

    defer transport.deinit();
    _ = allocator;

    if (data.len == 0) return error.EmptyData;

    const mtu = config.att_mtu;
    const dcs = Chunk.dataChunkSize(mtu);
    const total_usize = Chunk.chunksNeeded(data.len, mtu);
    if (total_usize > Chunk.max_chunks) return error.TooManyChunks;
    const total: u16 = @intCast(total_usize);

    const mask_len = Chunk.Bitmask.requiredBytes(total);
    var sndmask: [Chunk.max_mask_bytes]u8 = undefined;
    Chunk.Bitmask.initAllSet(sndmask[0..mask_len], total);

    var resp_buf: [Chunk.max_mtu]u8 = undefined;
    var timeout_count: u8 = 0;
    _ = try transport.write(&Chunk.write_start_magic);

    while (true) {
        try sendMarkedChunks(transport, data, sndmask[0..mask_len], total, dcs, config.send_redundancy);

        const resp_len = transport.read(config.timeout_ms, &resp_buf) catch |err| switch (err) {
            error.Timeout => {
                timeout_count += 1;
                if (timeout_count >= config.max_timeout_retries) return error.Timeout;
                _ = try transport.write(&Chunk.write_start_magic);
                continue;
            },
            else => return err,
        };
        timeout_count = 0;
        const payload = resp_buf[0..resp_len];

        if (Chunk.isAck(payload)) return;

        Chunk.Bitmask.initClear(sndmask[0..mask_len], total);
        var loss_seqs: [260]u16 = undefined;
        const loss_count = Chunk.decodeLossList(payload, &loss_seqs);
        if (loss_count == 0) return error.InvalidResponse;

        var accepted_loss = false;
        for (loss_seqs[0..loss_count]) |seq| {
            if (seq >= 1 and seq <= total) {
                Chunk.Bitmask.set(sndmask[0..mask_len], seq);
                accepted_loss = true;
            }
        }
        if (!accepted_loss) return error.InvalidResponse;
    }
}

fn sendMarkedChunks(
    transport: anytype,
    data: []const u8,
    sndmask: []const u8,
    total: u16,
    dcs: usize,
    send_redundancy: u8,
) !void {
    var chunk_buf: [Chunk.max_mtu]u8 = undefined;
    var i: u16 = 0;
    while (i < total) : (i += 1) {
        const seq: u16 = i + 1;
        if (!Chunk.Bitmask.isSet(sndmask, seq)) continue;

        const hdr = (Chunk.Header{ .total = total, .seq = seq }).encode();
        @memcpy(chunk_buf[0..Chunk.header_size], &hdr);

        const offset: usize = @as(usize, i) * dcs;
        const remaining = data.len - offset;
        const payload_len: usize = @min(remaining, dcs);
        @memcpy(
            chunk_buf[Chunk.header_size .. Chunk.header_size + payload_len],
            data[offset .. offset + payload_len],
        );

        const total_len = Chunk.header_size + payload_len;
        for (0..send_redundancy) |_| {
            _ = try transport.writeNoResp(chunk_buf[0..total_len]);
        }
    }
}

test "bt/unit_tests/host/xfer/write/sends_start_and_chunks_until_ack" {
    const std = @import("std");
    const embed_std = @import("embed_std");

    const AckTransport = struct {
        start_writes: usize = 0,
        chunk_seqs: [8]u16 = [_]u16{0} ** 8,
        chunk_count: usize = 0,
        deinited: bool = false,
        ack_sent: bool = false,

        fn read(self: *@This(), _: u32, out: []u8) !usize {
            if (self.ack_sent) return error.Closed;
            self.ack_sent = true;
            @memcpy(out[0..Chunk.ack_signal.len], &Chunk.ack_signal);
            return Chunk.ack_signal.len;
        }

        fn write(self: *@This(), data: []const u8) !usize {
            try std.testing.expectEqualSlices(u8, &Chunk.write_start_magic, data);
            self.start_writes += 1;
            return data.len;
        }

        fn writeNoResp(self: *@This(), data: []const u8) !usize {
            const hdr = Chunk.Header.decode(data[0..Chunk.header_size]);
            self.chunk_seqs[self.chunk_count] = hdr.seq;
            self.chunk_count += 1;
            return data.len;
        }

        fn deinit(self: *@This()) void {
            self.deinited = true;
        }
    };

    var data: [20]u8 = undefined;
    @memset(&data, 0xAB);

    var transport = AckTransport{};
    try write(embed_std.std, std.testing.allocator, &transport, &data, .{ .send_redundancy = 1 });

    try std.testing.expectEqual(@as(usize, 1), transport.start_writes);
    try std.testing.expectEqual(@as(usize, 2), transport.chunk_count);
    try std.testing.expectEqualSlices(u16, &.{ 1, 2 }, transport.chunk_seqs[0..transport.chunk_count]);
    try std.testing.expect(transport.deinited);
}

test "bt/unit_tests/host/xfer/write/retries_only_missing_chunks" {
    const std = @import("std");
    const embed_std = @import("embed_std");

    const Step = enum {
        loss,
        ack,
    };

    const RetryTransport = struct {
        steps: [2]Step = .{ .loss, .ack },
        step_index: usize = 0,
        chunk_seqs: [8]u16 = [_]u16{0} ** 8,
        chunk_count: usize = 0,
        deinited: bool = false,

        fn read(self: *@This(), _: u32, out: []u8) !usize {
            const step = self.steps[self.step_index];
            self.step_index += 1;
            switch (step) {
                .loss => {
                    const encoded = Chunk.encodeLossList(&.{2}, out);
                    return encoded.len;
                },
                .ack => {
                    @memcpy(out[0..Chunk.ack_signal.len], &Chunk.ack_signal);
                    return Chunk.ack_signal.len;
                },
            }
        }

        fn write(_: *@This(), data: []const u8) !usize {
            return data.len;
        }

        fn writeNoResp(self: *@This(), data: []const u8) !usize {
            const hdr = Chunk.Header.decode(data[0..Chunk.header_size]);
            self.chunk_seqs[self.chunk_count] = hdr.seq;
            self.chunk_count += 1;
            return data.len;
        }

        fn deinit(self: *@This()) void {
            self.deinited = true;
        }
    };

    var data: [20]u8 = undefined;
    @memset(&data, 0xCD);

    var transport = RetryTransport{};
    try write(embed_std.std, std.testing.allocator, &transport, &data, .{ .send_redundancy = 1 });

    try std.testing.expectEqual(@as(usize, 3), transport.chunk_count);
    try std.testing.expectEqualSlices(u16, &.{ 1, 2, 2 }, transport.chunk_seqs[0..transport.chunk_count]);
    try std.testing.expect(transport.deinited);
}

test "bt/unit_tests/host/xfer/write/retries_resend_start_after_timeout" {
    const std = @import("std");
    const embed_std = @import("embed_std");

    const RetryTransport = struct {
        read_count: usize = 0,
        start_writes: usize = 0,
        chunk_count: usize = 0,
        deinited: bool = false,

        fn read(self: *@This(), _: u32, out: []u8) !usize {
            switch (self.read_count) {
                0 => {
                    self.read_count += 1;
                    return error.Timeout;
                },
                1 => {
                    self.read_count += 1;
                    @memcpy(out[0..Chunk.ack_signal.len], &Chunk.ack_signal);
                    return Chunk.ack_signal.len;
                },
                else => return error.Closed,
            }
        }

        fn write(self: *@This(), data: []const u8) !usize {
            try std.testing.expectEqualSlices(u8, &Chunk.write_start_magic, data);
            self.start_writes += 1;
            return data.len;
        }

        fn writeNoResp(self: *@This(), _: []const u8) !usize {
            self.chunk_count += 1;
            return 1;
        }

        fn deinit(self: *@This()) void {
            self.deinited = true;
        }
    };

    var data: [20]u8 = undefined;
    @memset(&data, 0xEF);

    var transport = RetryTransport{};
    try write(embed_std.std, std.testing.allocator, &transport, &data, .{ .send_redundancy = 1 });

    try std.testing.expectEqual(@as(usize, 2), transport.start_writes);
    try std.testing.expectEqual(@as(usize, 4), transport.chunk_count);
    try std.testing.expect(transport.deinited);
}

test "bt/unit_tests/host/xfer/write/rejects_loss_list_without_valid_sequences" {
    const std = @import("std");
    const embed_std = @import("embed_std");

    const InvalidLossTransport = struct {
        read_count: usize = 0,
        deinited: bool = false,

        fn read(self: *@This(), _: u32, out: []u8) !usize {
            if (self.read_count != 0) return error.Closed;
            self.read_count += 1;
            const encoded = Chunk.encodeLossList(&.{999}, out);
            return encoded.len;
        }

        fn write(_: *@This(), data: []const u8) !usize {
            return data.len;
        }

        fn writeNoResp(_: *@This(), data: []const u8) !usize {
            return data.len;
        }

        fn deinit(self: *@This()) void {
            self.deinited = true;
        }
    };

    var data: [20]u8 = undefined;
    @memset(&data, 0xAA);

    var transport = InvalidLossTransport{};
    try std.testing.expectError(
        error.InvalidResponse,
        write(embed_std.std, std.testing.allocator, &transport, &data, .{ .send_redundancy = 1 }),
    );
    try std.testing.expect(transport.deinited);
}
