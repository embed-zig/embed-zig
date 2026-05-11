const stdz = @import("stdz");

pub fn Encoding(comptime alphabet: []const u8) type {
    comptime validateAlphabet(alphabet);

    return struct {
        pub const alphabet_chars = alphabet;
        pub const base = alphabet.len;
        pub const EncodeError = error{BufferTooSmall};
        pub const DecodeError = error{
            BufferTooSmall,
            InvalidCharacter,
        };

        pub fn encodedMaxLen(src_len: usize) usize {
            if (src_len == 0) return 0;
            return src_len * 8 + 1;
        }

        pub fn decodedMaxLen(src_len: usize) usize {
            return src_len;
        }

        pub fn encode(allocator: stdz.mem.Allocator, src: []const u8) ![]u8 {
            const scratch = try allocator.alloc(u8, encodedMaxLen(src.len));
            defer allocator.free(scratch);
            const out = try allocator.alloc(u8, encodedMaxLen(src.len));
            errdefer allocator.free(out);

            const encoded = try encodeBuf(src, out, scratch);
            if (encoded.len == out.len) return out;

            const resized = try allocator.alloc(u8, encoded.len);
            @memcpy(resized, encoded);
            allocator.free(out);
            return resized;
        }

        pub fn encodeBuf(src: []const u8, out: []u8, scratch: []u8) EncodeError![]u8 {
            var zeroes: usize = 0;
            while (zeroes < src.len and src[zeroes] == 0) : (zeroes += 1) {}

            const scratch_required = encodedMaxLen(src.len - zeroes);
            if (scratch.len < scratch_required) return error.BufferTooSmall;
            @memset(scratch, 0);

            var digit_len: usize = 0;
            for (src[zeroes..]) |byte| {
                var carry: usize = byte;
                var i: usize = 0;
                while (i < digit_len) : (i += 1) {
                    carry += @as(usize, scratch[i]) << 8;
                    scratch[i] = @intCast(carry % base);
                    carry /= base;
                }
                while (carry != 0) {
                    scratch[digit_len] = @intCast(carry % base);
                    digit_len += 1;
                    carry /= base;
                }
            }

            if (out.len < zeroes + digit_len) return error.BufferTooSmall;

            @memset(out[0..zeroes], alphabet[0]);
            var i: usize = 0;
            while (i < digit_len) : (i += 1) {
                out[zeroes + i] = alphabet[scratch[digit_len - 1 - i]];
            }
            return out[0 .. zeroes + digit_len];
        }

        pub fn decode(allocator: stdz.mem.Allocator, src: []const u8) ![]u8 {
            const scratch = try allocator.alloc(u8, decodedMaxLen(src.len));
            defer allocator.free(scratch);
            const out = try allocator.alloc(u8, decodedMaxLen(src.len));
            errdefer allocator.free(out);

            const decoded = try decodeBuf(src, out, scratch);
            if (decoded.len == out.len) return out;

            const resized = try allocator.alloc(u8, decoded.len);
            @memcpy(resized, decoded);
            allocator.free(out);
            return resized;
        }

        pub fn decodeBuf(src: []const u8, out: []u8, scratch: []u8) DecodeError![]u8 {
            var zeroes: usize = 0;
            while (zeroes < src.len and src[zeroes] == alphabet[0]) : (zeroes += 1) {}

            if (scratch.len < decodedMaxLen(src.len)) return error.BufferTooSmall;
            @memset(scratch, 0);

            var byte_len: usize = 0;
            for (src[zeroes..]) |byte| {
                var carry: usize = try decodeByte(byte);
                var i: usize = 0;
                while (i < byte_len) : (i += 1) {
                    carry += @as(usize, scratch[i]) * base;
                    scratch[i] = @intCast(carry & 0xff);
                    carry >>= 8;
                }
                while (carry != 0) {
                    scratch[byte_len] = @intCast(carry & 0xff);
                    byte_len += 1;
                    carry >>= 8;
                }
            }

            if (out.len < zeroes + byte_len) return error.BufferTooSmall;

            @memset(out[0..zeroes], 0);
            var i: usize = 0;
            while (i < byte_len) : (i += 1) {
                out[zeroes + i] = scratch[byte_len - 1 - i];
            }
            return out[0 .. zeroes + byte_len];
        }

        fn decodeByte(byte: u8) DecodeError!u8 {
            inline for (alphabet, 0..) |candidate, index| {
                if (byte == candidate) return @intCast(index);
            }
            return error.InvalidCharacter;
        }
    };
}

fn validateAlphabet(comptime alphabet: []const u8) void {
    if (alphabet.len < 2) @compileError("base58 alphabet must contain at least two characters");
    if (alphabet.len > 256) @compileError("base58 alphabet must not contain more than 256 characters");

    var seen = [_]bool{false} ** 256;
    for (alphabet) |byte| {
        if (seen[byte]) @compileError("base58 alphabet contains duplicate characters");
        seen[byte] = true;
    }
}
