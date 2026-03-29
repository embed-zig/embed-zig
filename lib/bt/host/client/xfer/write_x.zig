//! write_x — write a chunked payload through a transfer characteristic.

const chunk = @import("chunk.zig");

const default_mtu: u16 = 247;
const default_timeout_ms: u32 = 5_000;
const default_send_redundancy: u8 = 3;

pub fn write(characteristic: anytype, data: []const u8) !void {
    comptime requireCharacteristic(@TypeOf(characteristic));

    if (data.len == 0) return error.EmptyData;

    const mtu = default_mtu;
    const dcs = chunk.dataChunkSize(mtu);
    const total_usize = chunk.chunksNeeded(data.len, mtu);
    if (total_usize > chunk.max_chunks) return error.TooManyChunks;
    const total: u16 = @intCast(total_usize);

    const mask_len = chunk.Bitmask.requiredBytes(total);
    var sndmask: [chunk.max_mask_bytes]u8 = undefined;
    chunk.Bitmask.initAllSet(sndmask[0..mask_len], total);

    var sub = try characteristic.subscribe();
    defer sub.deinit();

    try characteristic.write(&chunk.write_start_magic);

    while (true) {
        try sendMarkedChunks(characteristic, data, sndmask[0..mask_len], total, dcs);

        const resp = (try sub.next(default_timeout_ms)) orelse return error.SubscriptionClosed;
        const payload = resp.payload();

        if (chunk.isAck(payload)) return;

        chunk.Bitmask.initClear(sndmask[0..mask_len], total);
        var loss_seqs: [260]u16 = undefined;
        const loss_count = chunk.decodeLossList(payload, &loss_seqs);
        if (loss_count == 0) return error.InvalidResponse;

        for (loss_seqs[0..loss_count]) |seq| {
            if (seq >= 1 and seq <= total) {
                chunk.Bitmask.set(sndmask[0..mask_len], seq);
            }
        }
    }
}

fn sendMarkedChunks(characteristic: anytype, data: []const u8, sndmask: []const u8, total: u16, dcs: usize) !void {
    var chunk_buf: [chunk.max_mtu]u8 = undefined;
    var i: u16 = 0;
    while (i < total) : (i += 1) {
        const seq: u16 = i + 1;
        if (!chunk.Bitmask.isSet(sndmask, seq)) continue;

        const hdr = (chunk.Header{ .total = total, .seq = seq }).encode();
        @memcpy(chunk_buf[0..chunk.header_size], &hdr);

        const offset: usize = @as(usize, i) * dcs;
        const remaining = data.len - offset;
        const payload_len: usize = @min(remaining, dcs);
        @memcpy(
            chunk_buf[chunk.header_size .. chunk.header_size + payload_len],
            data[offset .. offset + payload_len],
        );

        const total_len = chunk.header_size + payload_len;
        for (0..default_send_redundancy) |_| {
            characteristic.writeNoResp(chunk_buf[0..total_len]) catch |err| switch (err) {
                error.AttError => try characteristic.write(chunk_buf[0..total_len]),
                else => return err,
            };
        }
    }
}

fn requireCharacteristic(comptime T: type) void {
    if (@typeInfo(T) != .pointer) {
        @compileError("write_x.write expects *Characteristic");
    }

    const Child = @typeInfo(T).pointer.child;
    if (!@hasDecl(Child, "write")) @compileError("Characteristic must define write");
    if (!@hasDecl(Child, "writeNoResp")) @compileError("Characteristic must define writeNoResp");
    if (!@hasDecl(Child, "subscribe")) @compileError("Characteristic must define subscribe");
}
