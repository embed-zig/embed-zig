//! client — client-side xfer entrypoint.

const embed = @import("embed");
const Chunk = @import("Chunk.zig");

const default_att_mtu: u16 = 23;
const default_read_timeout_ms: u32 = 1_000;
const default_read_max_retries: u8 = 5;
const default_write_timeout_ms: u32 = 5_000;
const default_send_redundancy: u8 = 3;

pub const Topic = Chunk.Topic;

pub fn read(characteristic: anytype, allocator: embed.mem.Allocator) ![]u8 {
    return readRequest(characteristic, &Chunk.read_start_magic, allocator);
}

pub fn write(characteristic: anytype, data: []const u8) !void {
    comptime requireWritableCharacteristic(@TypeOf(characteristic));

    if (data.len == 0) return error.EmptyData;

    const mtu = effectiveMtu(characteristic);
    const dcs = Chunk.dataChunkSize(mtu);
    const total_usize = Chunk.chunksNeeded(data.len, mtu);
    if (total_usize > Chunk.max_chunks) return error.TooManyChunks;
    const total: u16 = @intCast(total_usize);

    const mask_len = Chunk.Bitmask.requiredBytes(total);
    var sndmask: [Chunk.max_mask_bytes]u8 = undefined;
    Chunk.Bitmask.initAllSet(sndmask[0..mask_len], total);

    var sub = try characteristic.subscribe();
    defer sub.deinit();

    try characteristic.write(&Chunk.write_start_magic);

    while (true) {
        try sendMarkedChunks(characteristic, data, sndmask[0..mask_len], total, dcs);

        const resp = (try sub.next(default_write_timeout_ms)) orelse return error.SubscriptionClosed;
        const payload = resp.payload();

        if (Chunk.isAck(payload)) return;

        Chunk.Bitmask.initClear(sndmask[0..mask_len], total);
        var loss_seqs: [260]u16 = undefined;
        const loss_count = Chunk.decodeLossList(payload, &loss_seqs);
        if (loss_count == 0) return error.InvalidResponse;

        for (loss_seqs[0..loss_count]) |seq| {
            if (seq >= 1 and seq <= total) {
                Chunk.Bitmask.set(sndmask[0..mask_len], seq);
            }
        }
    }
}

pub fn get(characteristic: anytype, topic: Topic, metadata: []const u8, allocator: embed.mem.Allocator) ![]u8 {
    comptime requireReadableCharacteristic(@TypeOf(characteristic));

    const request = try allocator.alloc(
        u8,
        Chunk.read_start_magic.len + Chunk.topic_size + metadata.len,
    );
    defer allocator.free(request);

    @memcpy(request[0..Chunk.read_start_magic.len], &Chunk.read_start_magic);
    _ = Chunk.encodeReadStartMetadata(request[Chunk.read_start_magic.len..], topic, metadata);
    return readRequest(characteristic, request, allocator);
}

fn readRequest(characteristic: anytype, request: []const u8, allocator: embed.mem.Allocator) ![]u8 {
    comptime requireReadableCharacteristic(@TypeOf(characteristic));

    const mtu = effectiveMtu(characteristic);
    const dcs = Chunk.dataChunkSize(mtu);
    const max_chunk_msg = @as(usize, mtu) - Chunk.att_overhead;

    var rcvmask: [Chunk.max_mask_bytes]u8 = undefined;
    var total: u16 = 0;
    var last_chunk_len: usize = 0;
    var initialized = false;
    var timeout_count: u8 = 0;
    var recv_buf: ?[]u8 = null;
    errdefer if (recv_buf) |buf| allocator.free(buf);

    var sub = try characteristic.subscribe();
    defer sub.deinit();

    try characteristic.write(request);

    while (true) {
        const notif = sub.next(default_read_timeout_ms) catch |err| switch (err) {
            error.TimedOut => {
                timeout_count += 1;
                if (timeout_count >= default_read_max_retries) return error.Timeout;
                if (!initialized) {
                    try characteristic.write(request);
                    continue;
                }
                try sendMissingReadChunks(characteristic, rcvmask[0..Chunk.Bitmask.requiredBytes(total)], total, max_chunk_msg);
                continue;
            },
            else => return err,
        } orelse return error.SubscriptionClosed;

        timeout_count = 0;
        const payload = notif.payload();
        if (payload.len < Chunk.header_size) return error.InvalidPacket;
        if (payload.len > max_chunk_msg) return error.ChunkTooLarge;

        const hdr = Chunk.Header.decode(payload[0..Chunk.header_size]);
        try hdr.validate();

        if (!initialized) {
            total = hdr.total;
            const mask_len = Chunk.Bitmask.requiredBytes(total);
            Chunk.Bitmask.initClear(rcvmask[0..mask_len], total);

            recv_buf = try allocator.alloc(u8, @as(usize, total) * dcs);
            initialized = true;
        } else if (hdr.total != total) {
            return error.TotalMismatch;
        }

        const payload_len = payload.len - Chunk.header_size;
        const idx: usize = @as(usize, hdr.seq) - 1;
        const write_at: usize = idx * dcs;
        const buf = recv_buf orelse unreachable;
        @memcpy(
            buf[write_at .. write_at + payload_len],
            payload[Chunk.header_size .. Chunk.header_size + payload_len],
        );

        if (hdr.seq == total) {
            last_chunk_len = payload_len;
        }

        const mask_len = Chunk.Bitmask.requiredBytes(total);
        Chunk.Bitmask.set(rcvmask[0..mask_len], hdr.seq);

        if (Chunk.Bitmask.isComplete(rcvmask[0..mask_len], total)) {
            try characteristic.write(&Chunk.ack_signal);
            const data_len = (@as(usize, total) - 1) * dcs + last_chunk_len;
            return try allocator.realloc(buf, data_len);
        }
    }
}

fn sendMarkedChunks(characteristic: anytype, data: []const u8, sndmask: []const u8, total: u16, dcs: usize) !void {
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
        for (0..default_send_redundancy) |_| {
            characteristic.writeNoResp(chunk_buf[0..total_len]) catch |err| switch (err) {
                error.AttError => try characteristic.write(chunk_buf[0..total_len]),
                else => return err,
            };
        }
    }
}

fn effectiveMtu(characteristic: anytype) u16 {
    const raw_mtu = characteristic.attMtu();
    if (raw_mtu < default_att_mtu) return default_att_mtu;
    return @min(raw_mtu, @as(u16, @intCast(Chunk.max_mtu)));
}

fn sendMissingReadChunks(characteristic: anytype, rcvmask: []const u8, total: u16, max_chunk_msg: usize) !void {
    var send_buf: [Chunk.max_mtu]u8 = undefined;
    var loss_seqs: [Chunk.max_mtu / 2]u16 = undefined;
    const batch_cap = @min(loss_seqs.len, max_chunk_msg / 2);

    var loss_count: usize = 0;
    var seq: u16 = 1;
    while (seq <= total) : (seq += 1) {
        if (Chunk.Bitmask.isSet(rcvmask, seq)) continue;
        loss_seqs[loss_count] = seq;
        loss_count += 1;
        if (loss_count == batch_cap) {
            const encoded = Chunk.encodeLossList(loss_seqs[0..loss_count], &send_buf);
            try characteristic.write(encoded);
            loss_count = 0;
        }
    }

    if (loss_count != 0) {
        const encoded = Chunk.encodeLossList(loss_seqs[0..loss_count], &send_buf);
        try characteristic.write(encoded);
    }
}

test "bt/unit_tests/host/xfer/client/sendMissingReadChunks_pages_large_loss_lists" {
    const std = @import("std");

    const FakeCharacteristic = struct {
        payloads: [4][Chunk.max_mtu]u8 = undefined,
        lens: [4]usize = [_]usize{0} ** 4,
        count: usize = 0,

        fn write(self: *@This(), data: []const u8) !void {
            @memcpy(self.payloads[self.count][0..data.len], data);
            self.lens[self.count] = data.len;
            self.count += 1;
        }
    };

    var rcvmask: [Chunk.max_mask_bytes]u8 = undefined;
    Chunk.Bitmask.initClear(rcvmask[0..Chunk.Bitmask.requiredBytes(300)], 300);

    var characteristic = FakeCharacteristic{};
    try sendMissingReadChunks(&characteristic, rcvmask[0..Chunk.Bitmask.requiredBytes(300)], 300, 244);
    try std.testing.expectEqual(@as(usize, 3), characteristic.count);

    var recovered: [300]u16 = undefined;
    var recovered_len: usize = 0;
    var decoded: [Chunk.max_mtu / 2]u16 = undefined;
    for (0..characteristic.count) |i| {
        const count = Chunk.decodeLossList(characteristic.payloads[i][0..characteristic.lens[i]], &decoded);
        @memcpy(recovered[recovered_len .. recovered_len + count], decoded[0..count]);
        recovered_len += count;
    }

    try std.testing.expectEqual(@as(usize, 300), recovered_len);
    for (recovered, 0..) |seq, i| {
        try std.testing.expectEqual(@as(u16, @intCast(i + 1)), seq);
    }
}

test "bt/unit_tests/host/xfer/client/write_uses_characteristic_att_mtu_for_chunking" {
    const std = @import("std");

    const AckMessage = struct {
        data: [Chunk.ack_signal.len]u8 = Chunk.ack_signal,

        fn payload(self: *const @This()) []const u8 {
            return &self.data;
        }
    };

    const FakeSubscription = struct {
        delivered: bool = false,

        fn deinit(_: *@This()) void {}

        fn next(self: *@This(), _: u32) !?AckMessage {
            if (self.delivered) return null;
            self.delivered = true;
            return .{};
        }
    };

    const FakeCharacteristic = struct {
        mtu: u16 = 30,
        start_writes: usize = 0,
        no_resp_writes: usize = 0,
        seqs: [9]u16 = [_]u16{0} ** 9,

        fn attMtu(self: *const @This()) u16 {
            return self.mtu;
        }

        fn subscribe(_: *@This()) !FakeSubscription {
            return .{};
        }

        fn write(self: *@This(), data: []const u8) !void {
            if (std.mem.eql(u8, data, &Chunk.write_start_magic)) {
                self.start_writes += 1;
                return;
            }
            return error.Unexpected;
        }

        fn writeNoResp(self: *@This(), data: []const u8) !void {
            const hdr = Chunk.Header.decode(data[0..Chunk.header_size]);
            self.seqs[self.no_resp_writes] = hdr.seq;
            self.no_resp_writes += 1;
        }
    };

    var data: [56]u8 = undefined;
    @memset(&data, 0xAB);

    var characteristic = FakeCharacteristic{};
    try write(&characteristic, &data);

    try std.testing.expectEqual(@as(usize, 1), characteristic.start_writes);
    try std.testing.expectEqual(@as(usize, 9), characteristic.no_resp_writes);
    try std.testing.expectEqualSlices(
        u16,
        &[_]u16{ 1, 1, 1, 2, 2, 2, 3, 3, 3 },
        &characteristic.seqs,
    );
}

test "bt/unit_tests/host/xfer/client/read_retries_request_before_first_chunk_arrives" {
    const std = @import("std");

    const Message = struct {
        data: [Chunk.header_size + 5]u8 = undefined,
        len: usize = 0,

        fn payload(self: *const @This()) []const u8 {
            return self.data[0..self.len];
        }
    };

    const FakeSubscription = struct {
        step: usize = 0,
        first: Message,

        fn deinit(_: *@This()) void {}

        fn next(self: *@This(), _: u32) !?Message {
            switch (self.step) {
                0, 1 => {
                    self.step += 1;
                    return error.TimedOut;
                },
                2 => {
                    self.step += 1;
                    return self.first;
                },
                else => return null,
            }
        }
    };

    const FakeCharacteristic = struct {
        mtu: u16 = 30,
        start_writes: usize = 0,
        ack_writes: usize = 0,
        subscription: FakeSubscription,

        fn attMtu(self: *const @This()) u16 {
            return self.mtu;
        }

        fn subscribe(self: *@This()) !*FakeSubscription {
            return &self.subscription;
        }

        fn write(self: *@This(), data: []const u8) !void {
            if (embed.mem.eql(u8, data, &Chunk.read_start_magic)) {
                self.start_writes += 1;
                return;
            }
            if (embed.mem.eql(u8, data, &Chunk.ack_signal)) {
                self.ack_writes += 1;
                return;
            }
            return error.Unexpected;
        }
    };

    var first = Message{};
    const hdr = (Chunk.Header{ .total = 1, .seq = 1 }).encode();
    @memcpy(first.data[0..Chunk.header_size], &hdr);
    @memcpy(first.data[Chunk.header_size .. Chunk.header_size + 5], "hello");
    first.len = Chunk.header_size + 5;

    var characteristic = FakeCharacteristic{
        .subscription = .{ .first = first },
    };
    const payload = try read(&characteristic, std.testing.allocator);
    defer std.testing.allocator.free(payload);

    try std.testing.expectEqual(@as(usize, 3), characteristic.start_writes);
    try std.testing.expectEqual(@as(usize, 1), characteristic.ack_writes);
    try std.testing.expectEqualSlices(u8, "hello", payload);
}

test "bt/unit_tests/host/xfer/client/get_sends_topic_and_metadata" {
    const std = @import("std");

    const Message = struct {
        data: [Chunk.header_size + 2]u8 = undefined,
        len: usize = 0,

        fn payload(self: *const @This()) []const u8 {
            return self.data[0..self.len];
        }
    };

    const FakeSubscription = struct {
        delivered: bool = false,
        msg: Message,

        fn deinit(_: *@This()) void {}

        fn next(self: *@This(), _: u32) !?Message {
            if (self.delivered) return null;
            self.delivered = true;
            return self.msg;
        }
    };

    const FakeCharacteristic = struct {
        mtu: u16 = 30,
        writes: [2][Chunk.read_start_magic.len + Chunk.topic_size + 4]u8 = undefined,
        lens: [2]usize = [_]usize{0} ** 2,
        write_count: usize = 0,
        subscription: FakeSubscription,

        fn attMtu(self: *const @This()) u16 {
            return self.mtu;
        }

        fn subscribe(self: *@This()) !*FakeSubscription {
            return &self.subscription;
        }

        fn write(self: *@This(), data: []const u8) !void {
            @memcpy(self.writes[self.write_count][0..data.len], data);
            self.lens[self.write_count] = data.len;
            self.write_count += 1;
        }
    };

    var msg = Message{};
    const hdr = (Chunk.Header{ .total = 1, .seq = 1 }).encode();
    @memcpy(msg.data[0..Chunk.header_size], &hdr);
    @memcpy(msg.data[Chunk.header_size .. Chunk.header_size + 2], "ok");
    msg.len = Chunk.header_size + 2;

    var characteristic = FakeCharacteristic{
        .subscription = .{ .msg = msg },
    };
    const payload = try get(&characteristic, 0x0102030405060708, "meta", std.testing.allocator);
    defer std.testing.allocator.free(payload);

    var expected: [Chunk.read_start_magic.len + Chunk.topic_size + 4]u8 = undefined;
    @memcpy(expected[0..Chunk.read_start_magic.len], &Chunk.read_start_magic);
    const expected_len = Chunk.read_start_magic.len + Chunk.encodeReadStartMetadata(
        expected[Chunk.read_start_magic.len..],
        0x0102030405060708,
        "meta",
    ).len;

    try std.testing.expectEqual(@as(usize, 2), characteristic.write_count);
    try std.testing.expectEqual(expected_len, characteristic.lens[0]);
    try std.testing.expectEqualSlices(u8, expected[0..expected_len], characteristic.writes[0][0..characteristic.lens[0]]);
    try std.testing.expectEqual(@as(usize, Chunk.ack_signal.len), characteristic.lens[1]);
    try std.testing.expectEqualSlices(u8, &Chunk.ack_signal, characteristic.writes[1][0..characteristic.lens[1]]);
    try std.testing.expectEqualSlices(u8, "ok", payload);
}

test "bt/unit_tests/host/xfer/client/get_retries_same_topic_and_metadata_before_first_chunk" {
    const std = @import("std");

    const Message = struct {
        data: [Chunk.header_size + 5]u8 = undefined,
        len: usize = 0,

        fn payload(self: *const @This()) []const u8 {
            return self.data[0..self.len];
        }
    };

    const FakeSubscription = struct {
        step: usize = 0,
        msg: Message,

        fn deinit(_: *@This()) void {}

        fn next(self: *@This(), _: u32) !?Message {
            switch (self.step) {
                0, 1 => {
                    self.step += 1;
                    return error.TimedOut;
                },
                2 => {
                    self.step += 1;
                    return self.msg;
                },
                else => return null,
            }
        }
    };

    const FakeCharacteristic = struct {
        mtu: u16 = 30,
        writes: [4][Chunk.read_start_magic.len + Chunk.topic_size + 4]u8 = undefined,
        lens: [4]usize = [_]usize{0} ** 4,
        write_count: usize = 0,
        subscription: FakeSubscription,

        fn attMtu(self: *const @This()) u16 {
            return self.mtu;
        }

        fn subscribe(self: *@This()) !*FakeSubscription {
            return &self.subscription;
        }

        fn write(self: *@This(), data: []const u8) !void {
            @memcpy(self.writes[self.write_count][0..data.len], data);
            self.lens[self.write_count] = data.len;
            self.write_count += 1;
        }
    };

    var msg = Message{};
    const hdr = (Chunk.Header{ .total = 1, .seq = 1 }).encode();
    @memcpy(msg.data[0..Chunk.header_size], &hdr);
    @memcpy(msg.data[Chunk.header_size .. Chunk.header_size + 5], "hello");
    msg.len = Chunk.header_size + 5;

    var characteristic = FakeCharacteristic{
        .subscription = .{ .msg = msg },
    };
    const payload = try get(&characteristic, 0x0102030405060708, "meta", std.testing.allocator);
    defer std.testing.allocator.free(payload);

    var expected: [Chunk.read_start_magic.len + Chunk.topic_size + 4]u8 = undefined;
    @memcpy(expected[0..Chunk.read_start_magic.len], &Chunk.read_start_magic);
    const expected_len = Chunk.read_start_magic.len + Chunk.encodeReadStartMetadata(
        expected[Chunk.read_start_magic.len..],
        0x0102030405060708,
        "meta",
    ).len;

    try std.testing.expectEqual(@as(usize, 4), characteristic.write_count);
    try std.testing.expectEqual(expected_len, characteristic.lens[0]);
    try std.testing.expectEqual(expected_len, characteristic.lens[1]);
    try std.testing.expectEqual(expected_len, characteristic.lens[2]);
    try std.testing.expectEqualSlices(u8, expected[0..expected_len], characteristic.writes[0][0..characteristic.lens[0]]);
    try std.testing.expectEqualSlices(u8, expected[0..expected_len], characteristic.writes[1][0..characteristic.lens[1]]);
    try std.testing.expectEqualSlices(u8, expected[0..expected_len], characteristic.writes[2][0..characteristic.lens[2]]);
    try std.testing.expectEqual(@as(usize, Chunk.ack_signal.len), characteristic.lens[3]);
    try std.testing.expectEqualSlices(u8, &Chunk.ack_signal, characteristic.writes[3][0..characteristic.lens[3]]);
    try std.testing.expectEqualSlices(u8, "hello", payload);
}

fn requireReadableCharacteristic(comptime T: type) void {
    if (@typeInfo(T) != .pointer) {
        @compileError("xfer.client.read expects *Characteristic");
    }

    const Child = @typeInfo(T).pointer.child;
    if (!@hasDecl(Child, "attMtu")) @compileError("Characteristic must define attMtu");
    if (!@hasDecl(Child, "write")) @compileError("Characteristic must define write");
    if (!@hasDecl(Child, "subscribe")) @compileError("Characteristic must define subscribe");
}

fn requireWritableCharacteristic(comptime T: type) void {
    if (@typeInfo(T) != .pointer) {
        @compileError("xfer.client.write expects *Characteristic");
    }

    const Child = @typeInfo(T).pointer.child;
    if (!@hasDecl(Child, "attMtu")) @compileError("Characteristic must define attMtu");
    if (!@hasDecl(Child, "write")) @compileError("Characteristic must define write");
    if (!@hasDecl(Child, "writeNoResp")) @compileError("Characteristic must define writeNoResp");
    if (!@hasDecl(Child, "subscribe")) @compileError("Characteristic must define subscribe");
}
