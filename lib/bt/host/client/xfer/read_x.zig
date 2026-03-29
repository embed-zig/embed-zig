//! read_x — read a chunked payload from a transfer characteristic.

const embed = @import("embed");
const chunk = @import("chunk.zig");

const default_mtu: u16 = 247;
const default_timeout_ms: u32 = 1_000;
const default_max_retries: u8 = 5;

pub fn read(characteristic: anytype, allocator: embed.mem.Allocator) ![]u8 {
    comptime requireCharacteristic(@TypeOf(characteristic));

    const mtu = default_mtu;
    const dcs = chunk.dataChunkSize(mtu);
    const max_chunk_msg = @as(usize, mtu) - chunk.att_overhead;

    var rcvmask: [chunk.max_mask_bytes]u8 = undefined;
    var total: u16 = 0;
    var last_chunk_len: usize = 0;
    var initialized = false;
    var timeout_count: u8 = 0;
    var recv_buf: ?[]u8 = null;
    errdefer if (recv_buf) |buf| allocator.free(buf);

    var sub = try characteristic.subscribe();
    defer sub.deinit();

    try characteristic.write(&chunk.read_start_magic);

    while (true) {
        const notif = sub.next(default_timeout_ms) catch |err| switch (err) {
            error.TimedOut => {
                timeout_count += 1;
                if (timeout_count >= default_max_retries) return error.Timeout;
                if (!initialized) continue;

                const mask_len = chunk.Bitmask.requiredBytes(total);
                var loss_seqs: [260]u16 = undefined;
                const max_seqs: usize = max_chunk_msg / 2;
                const loss_count = chunk.Bitmask.collectMissing(
                    rcvmask[0..mask_len],
                    total,
                    loss_seqs[0..@min(loss_seqs.len, max_seqs)],
                );
                if (loss_count == 0) continue;

                var send_buf: [chunk.max_mtu]u8 = undefined;
                const encoded = chunk.encodeLossList(loss_seqs[0..loss_count], &send_buf);
                try characteristic.write(encoded);
                continue;
            },
            else => return err,
        } orelse return error.SubscriptionClosed;

        timeout_count = 0;
        const payload = notif.payload();
        if (payload.len < chunk.header_size) return error.InvalidPacket;
        if (payload.len > max_chunk_msg) return error.ChunkTooLarge;

        const hdr = chunk.Header.decode(payload[0..chunk.header_size]);
        try hdr.validate();

        if (!initialized) {
            total = hdr.total;
            const mask_len = chunk.Bitmask.requiredBytes(total);
            chunk.Bitmask.initClear(rcvmask[0..mask_len], total);

            recv_buf = try allocator.alloc(u8, @as(usize, total) * dcs);
            initialized = true;
        } else if (hdr.total != total) {
            return error.TotalMismatch;
        }

        const payload_len = payload.len - chunk.header_size;
        const idx: usize = @as(usize, hdr.seq) - 1;
        const write_at: usize = idx * dcs;
        const buf = recv_buf orelse unreachable;
        @memcpy(
            buf[write_at .. write_at + payload_len],
            payload[chunk.header_size .. chunk.header_size + payload_len],
        );

        if (hdr.seq == total) {
            last_chunk_len = payload_len;
        }

        const mask_len = chunk.Bitmask.requiredBytes(total);
        chunk.Bitmask.set(rcvmask[0..mask_len], hdr.seq);

        if (chunk.Bitmask.isComplete(rcvmask[0..mask_len], total)) {
            try characteristic.write(&chunk.ack_signal);
            const data_len = (@as(usize, total) - 1) * dcs + last_chunk_len;
            return try allocator.realloc(buf, data_len);
        }
    }
}

fn requireCharacteristic(comptime T: type) void {
    if (@typeInfo(T) != .pointer) {
        @compileError("read_x.read expects *Characteristic");
    }

    const Child = @typeInfo(T).pointer.child;
    if (!@hasDecl(Child, "write")) @compileError("Characteristic must define write");
    if (!@hasDecl(Child, "subscribe")) @compileError("Characteristic must define subscribe");
}
