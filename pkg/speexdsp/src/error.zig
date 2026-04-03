const binding = @import("binding.zig");

pub const InitError = error{
    InvalidArgument,
    OutOfMemory,
    Unexpected,
};

pub const ControlError = error{
    Unexpected,
};

pub const ResamplerError = error{
    OutOfMemory,
    BadState,
    InvalidArgument,
    PointerOverlap,
    Overflow,
    Unexpected,
};

pub const ResamplerErrorCode = enum(c_int) {
    success = binding.RESAMPLER_ERR_SUCCESS,
    alloc_failed = binding.RESAMPLER_ERR_ALLOC_FAILED,
    bad_state = binding.RESAMPLER_ERR_BAD_STATE,
    invalid_arg = binding.RESAMPLER_ERR_INVALID_ARG,
    ptr_overlap = binding.RESAMPLER_ERR_PTR_OVERLAP,
    overflow = binding.RESAMPLER_ERR_OVERFLOW,
};

pub fn fromCtlStatus(status: c_int) ControlError!void {
    if (status == 0) return;
    return error.Unexpected;
}

pub fn fromResamplerStatus(status: c_int) ResamplerError!void {
    switch (status) {
        binding.RESAMPLER_ERR_SUCCESS => return,
        binding.RESAMPLER_ERR_ALLOC_FAILED => return error.OutOfMemory,
        binding.RESAMPLER_ERR_BAD_STATE => return error.BadState,
        binding.RESAMPLER_ERR_INVALID_ARG => return error.InvalidArgument,
        binding.RESAMPLER_ERR_PTR_OVERLAP => return error.PointerOverlap,
        binding.RESAMPLER_ERR_OVERFLOW => return error.Overflow,
        else => return error.Unexpected,
    }
}

pub fn fromResamplerStatusOrInit(status: c_int) InitError!void {
    switch (status) {
        binding.RESAMPLER_ERR_SUCCESS => return,
        binding.RESAMPLER_ERR_ALLOC_FAILED => return error.OutOfMemory,
        binding.RESAMPLER_ERR_INVALID_ARG => return error.InvalidArgument,
        else => return error.Unexpected,
    }
}

pub fn toResamplerErrorCode(status: c_int) ?ResamplerErrorCode {
    return switch (status) {
        binding.RESAMPLER_ERR_SUCCESS => .success,
        binding.RESAMPLER_ERR_ALLOC_FAILED => .alloc_failed,
        binding.RESAMPLER_ERR_BAD_STATE => .bad_state,
        binding.RESAMPLER_ERR_INVALID_ARG => .invalid_arg,
        binding.RESAMPLER_ERR_PTR_OVERLAP => .ptr_overlap,
        binding.RESAMPLER_ERR_OVERFLOW => .overflow,
        else => null,
    };
}

pub fn resamplerErrorText(status: c_int) [*:0]const u8 {
    return binding.speex_resampler_strerror(status);
}

test "speexdsp/unit_tests/error/maps_resampler_status_codes" {
    const std = @import("std");
    const testing = std.testing;

    try testing.expectEqual(ResamplerErrorCode.success, toResamplerErrorCode(binding.RESAMPLER_ERR_SUCCESS).?);
    try testing.expectEqual(ResamplerErrorCode.invalid_arg, toResamplerErrorCode(binding.RESAMPLER_ERR_INVALID_ARG).?);
    try testing.expectEqual(@as(?ResamplerErrorCode, null), toResamplerErrorCode(999));
}

test "speexdsp/unit_tests/error/exposes_resampler_text" {
    const std = @import("std");
    const testing = std.testing;

    const msg = resamplerErrorText(binding.RESAMPLER_ERR_INVALID_ARG);
    try testing.expect(msg[0] != 0);
}

test "speexdsp/unit_tests/error/maps_ctl_status_and_init_status" {
    const std = @import("std");
    const testing = std.testing;

    try fromCtlStatus(0);
    try testing.expectError(error.Unexpected, fromCtlStatus(-1));

    try fromResamplerStatusOrInit(binding.RESAMPLER_ERR_SUCCESS);
    try testing.expectError(error.OutOfMemory, fromResamplerStatusOrInit(binding.RESAMPLER_ERR_ALLOC_FAILED));
    try testing.expectError(error.InvalidArgument, fromResamplerStatusOrInit(binding.RESAMPLER_ERR_INVALID_ARG));
    try testing.expectError(error.Unexpected, fromResamplerStatusOrInit(binding.RESAMPLER_ERR_BAD_STATE));
}
