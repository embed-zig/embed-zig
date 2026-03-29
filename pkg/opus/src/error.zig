const binding = @import("binding.zig");
const Error = @import("types.zig").Error;

pub fn checkError(code: c_int) Error!void {
    if (code < 0) {
        return switch (code) {
            binding.OPUS_BAD_ARG => Error.BadArg,
            binding.OPUS_BUFFER_TOO_SMALL => Error.BufferTooSmall,
            binding.OPUS_INTERNAL_ERROR => Error.InternalError,
            binding.OPUS_INVALID_PACKET => Error.InvalidPacket,
            binding.OPUS_UNIMPLEMENTED => Error.Unimplemented,
            binding.OPUS_INVALID_STATE => Error.InvalidState,
            binding.OPUS_ALLOC_FAIL => Error.AllocFail,
            else => Error.Unknown,
        };
    }
}

pub fn checkedPositive(code: c_int) Error!usize {
    try checkError(code);
    return @intCast(code);
}

test "opus/unit_tests/error/maps_negative_code_to_typed_error" {
    const std = @import("std");
    const testing = std.testing;

    try testing.expectError(Error.BadArg, checkError(binding.OPUS_BAD_ARG));
    try testing.expectError(Error.InvalidState, checkError(binding.OPUS_INVALID_STATE));
}

test "opus/unit_tests/error/accepts_non_negative_return_codes" {
    try checkError(0);
    try checkError(3);
}
