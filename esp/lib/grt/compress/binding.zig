pub const ok: c_int = 0;
pub const invalid_data: c_int = -1;
pub const truncated_input: c_int = -2;
pub const output_too_small: c_int = -3;
pub const unsupported: c_int = -4;
pub const unexpected: c_int = -5;
pub const callback_error: c_int = -6;

pub const StreamCallback = *const fn (data: [*]const u8, len: usize, ctx: ?*anyopaque) callconv(.c) c_int;

pub extern fn espz_compress_inflate(
    container: c_int,
    compressed: [*]const u8,
    compressed_len: usize,
    out: [*]u8,
    out_len: usize,
    written: *usize,
) c_int;

pub extern fn espz_compress_inflate_stream(
    container: c_int,
    compressed: [*]const u8,
    compressed_len: usize,
    callback: StreamCallback,
    ctx: ?*anyopaque,
    written: *usize,
) c_int;
