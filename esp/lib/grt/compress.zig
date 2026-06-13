const glib = @import("glib");
const binding = @import("compress/binding.zig");

const compress = glib.compress;

pub const impl = struct {
    pub fn inflate(container: compress.Container, compressed: []const u8, out: []u8) compress.InflateError!usize {
        var written: usize = 0;
        const status = binding.espz_compress_inflate(
            @intFromEnum(container),
            compressed.ptr,
            compressed.len,
            out.ptr,
            out.len,
            &written,
        );
        return switch (status) {
            binding.ok => written,
            binding.invalid_data => error.InvalidData,
            binding.truncated_input => error.TruncatedInput,
            binding.output_too_small => error.OutputTooSmall,
            binding.unsupported => error.Unsupported,
            else => error.Unexpected,
        };
    }
};
