const hmac = @import("../mac/hmac.zig");

pub const HkdfSha256 = HkdfImpl(hmac.HmacSha256);
pub const HkdfSha384 = HkdfImpl(hmac.HmacSha384);

fn HkdfImpl(comptime Hmac: type) type {
    return struct {
        pub const prk_length = Hmac.mac_length;

        pub fn extract(salt: []const u8, ikm: []const u8) [prk_length]u8 {
            var out: [prk_length]u8 = undefined;
            Hmac.create(&out, ikm, salt);
            return out;
        }

        pub fn expand(out: []u8, ctx: []const u8, prk: [prk_length]u8) void {
            if (out.len > 255 * prk_length) @panic("HKDF output too large");

            var counter: usize = 1;
            var pos: usize = 0;
            var prev: [prk_length]u8 = undefined;
            var prev_len: usize = 0;

            while (pos < out.len) : (counter += 1) {
                var h = Hmac.init(&prk);
                h.update(prev[0..prev_len]);
                h.update(ctx);
                const counter_byte: [1]u8 = .{@intCast(counter)};
                h.update(&counter_byte);
                h.final(&prev);

                const n = @min(prk_length, out.len - pos);
                @memcpy(out[pos..][0..n], prev[0..n]);
                pos += n;
                prev_len = prk_length;
            }
        }
    };
}
