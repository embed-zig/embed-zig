const stdz = @import("stdz");

pub const Options = struct {
    alphabet: *const [32]u8,
    case_insensitive: bool = false,
    ignore_hyphen: bool = false,
    crockford_aliases: bool = false,
};

pub fn Encoding(comptime options: Options) type {
    comptime validateAlphabet(options.alphabet);

    return struct {
        pub const alphabet = options.alphabet;
        pub const EncodeError = error{BufferTooSmall};
        pub const DecodeError = error{
            BufferTooSmall,
            InvalidCharacter,
            InvalidPadding,
        };

        pub fn encodedLen(src_len: usize) usize {
            return (src_len * 8 + 4) / 5;
        }

        pub fn encode(allocator: stdz.mem.Allocator, src: []const u8) stdz.mem.Allocator.Error![]u8 {
            const out = try allocator.alloc(u8, encodedLen(src.len));
            _ = encodeBuf(src, out) catch unreachable;
            return out;
        }

        pub fn encodeBuf(src: []const u8, out: []u8) EncodeError![]u8 {
            if (out.len < encodedLen(src.len)) return error.BufferTooSmall;

            var out_len: usize = 0;
            var acc: u16 = 0;
            var bits: usize = 0;

            for (src) |byte| {
                acc = (acc << 8) | byte;
                bits += 8;

                while (bits >= 5) {
                    bits -= 5;
                    out[out_len] = alphabet[(acc >> @intCast(bits)) & 0x1f];
                    out_len += 1;
                    acc &= lowMask(bits);
                }
            }

            if (bits != 0) {
                out[out_len] = alphabet[(acc << @intCast(5 - bits)) & 0x1f];
                out_len += 1;
            }

            stdz.debug.assert(out_len == encodedLen(src.len));
            return out[0..out_len];
        }

        pub fn decode(allocator: stdz.mem.Allocator, src: []const u8) ![]u8 {
            const out = try allocator.alloc(u8, (src.len * 5) / 8);
            errdefer allocator.free(out);
            const decoded = try decodeBuf(src, out);
            return shrink(allocator, out, decoded.len);
        }

        pub fn decodeBuf(src: []const u8, out: []u8) DecodeError![]u8 {
            const max_len = (src.len * 5) / 8;
            if (out.len < max_len) return error.BufferTooSmall;

            var out_len: usize = 0;
            var acc: u16 = 0;
            var bits: usize = 0;

            for (src) |byte| {
                if (options.ignore_hyphen and byte == '-') continue;

                const value = try decodeByte(byte);
                acc = (acc << 5) | value;
                bits += 5;

                while (bits >= 8) {
                    bits -= 8;
                    if (out_len == out.len) return error.BufferTooSmall;
                    out[out_len] = @intCast((acc >> @intCast(bits)) & 0xff);
                    out_len += 1;
                    acc &= lowMask(bits);
                }
            }

            if (bits != 0 and acc != 0) return error.InvalidPadding;
            return out[0..out_len];
        }

        fn decodeByte(byte: u8) DecodeError!u16 {
            if (options.crockford_aliases) {
                switch (byte) {
                    'O', 'o' => return 0,
                    'I', 'i', 'L', 'l' => return 1,
                    else => {},
                }
            }

            inline for (alphabet, 0..) |candidate, index| {
                if (byte == candidate) return @intCast(index);
                if (options.case_insensitive and toLower(byte) == toLower(candidate)) return @intCast(index);
            }
            return error.InvalidCharacter;
        }
    };
}

fn validateAlphabet(comptime alphabet: *const [32]u8) void {
    var seen = [_]bool{false} ** 256;
    for (alphabet) |byte| {
        if (seen[byte]) @compileError("base32 alphabet contains duplicate characters");
        seen[byte] = true;
    }
}

fn lowMask(bits: usize) u16 {
    if (bits == 0) return 0;
    return (@as(u16, 1) << @intCast(bits)) - 1;
}

fn toLower(byte: u8) u8 {
    return if (byte >= 'A' and byte <= 'Z') byte + ('a' - 'A') else byte;
}

fn shrink(allocator: stdz.mem.Allocator, bytes: []u8, len: usize) stdz.mem.Allocator.Error![]u8 {
    if (bytes.len == len) return bytes;

    const out = try allocator.alloc(u8, len);
    @memcpy(out, bytes[0..len]);
    allocator.free(bytes);
    return out;
}
