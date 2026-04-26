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

pub fn TestRunner(comptime lib: type) @import("testing").TestRunner {
    const testing_api = @import("testing");

    const TestCase = struct {
        fn mapsResamplerStatusCodes() !void {
            try lib.testing.expectEqual(ResamplerErrorCode.success, toResamplerErrorCode(binding.RESAMPLER_ERR_SUCCESS).?);
            try lib.testing.expectEqual(ResamplerErrorCode.invalid_arg, toResamplerErrorCode(binding.RESAMPLER_ERR_INVALID_ARG).?);
            try lib.testing.expectEqual(@as(?ResamplerErrorCode, null), toResamplerErrorCode(999));
        }

        fn exposesResamplerText() !void {
            const msg = resamplerErrorText(binding.RESAMPLER_ERR_INVALID_ARG);
            try lib.testing.expect(msg[0] != 0);
        }

        fn mapsCtlStatusAndInitStatus() !void {
            try fromCtlStatus(0);
            try lib.testing.expectError(error.Unexpected, fromCtlStatus(-1));

            try fromResamplerStatusOrInit(binding.RESAMPLER_ERR_SUCCESS);
            try lib.testing.expectError(error.OutOfMemory, fromResamplerStatusOrInit(binding.RESAMPLER_ERR_ALLOC_FAILED));
            try lib.testing.expectError(error.InvalidArgument, fromResamplerStatusOrInit(binding.RESAMPLER_ERR_INVALID_ARG));
            try lib.testing.expectError(error.Unexpected, fromResamplerStatusOrInit(binding.RESAMPLER_ERR_BAD_STATE));
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            TestCase.mapsResamplerStatusCodes() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.exposesResamplerText() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.mapsCtlStatusAndInitStatus() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: lib.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}
