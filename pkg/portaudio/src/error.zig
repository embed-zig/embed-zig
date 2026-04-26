const glib = @import("glib");
const binding = @import("binding.zig");

pub const ErrorCode = enum(c_int) {
    no_error = binding.paNoError,
    not_initialized = binding.paNotInitialized,
    unanticipated_host_error = binding.paUnanticipatedHostError,
    invalid_channel_count = binding.paInvalidChannelCount,
    invalid_sample_rate = binding.paInvalidSampleRate,
    invalid_device = binding.paInvalidDevice,
    invalid_flag = binding.paInvalidFlag,
    sample_format_not_supported = binding.paSampleFormatNotSupported,
    bad_io_device_combination = binding.paBadIODeviceCombination,
    insufficient_memory = binding.paInsufficientMemory,
    buffer_too_big = binding.paBufferTooBig,
    buffer_too_small = binding.paBufferTooSmall,
    null_callback = binding.paNullCallback,
    bad_stream_ptr = binding.paBadStreamPtr,
    timed_out = binding.paTimedOut,
    internal_error = binding.paInternalError,
    device_unavailable = binding.paDeviceUnavailable,
    incompatible_host_api_specific_stream_info = binding.paIncompatibleHostApiSpecificStreamInfo,
    stream_is_stopped = binding.paStreamIsStopped,
    stream_is_not_stopped = binding.paStreamIsNotStopped,
    input_overflowed = binding.paInputOverflowed,
    output_underflowed = binding.paOutputUnderflowed,
    host_api_not_found = binding.paHostApiNotFound,
    invalid_host_api = binding.paInvalidHostApi,
    can_not_read_from_a_callback_stream = binding.paCanNotReadFromACallbackStream,
    can_not_write_to_a_callback_stream = binding.paCanNotWriteToACallbackStream,
    can_not_read_from_an_output_only_stream = binding.paCanNotReadFromAnOutputOnlyStream,
    can_not_write_to_an_input_only_stream = binding.paCanNotWriteToAnInputOnlyStream,
    incompatible_stream_host_api = binding.paIncompatibleStreamHostApi,
    bad_buffer_ptr = binding.paBadBufferPtr,
};

pub const Error = error{
    NotInitialized,
    UnanticipatedHostError,
    InvalidChannelCount,
    InvalidSampleRate,
    InvalidDevice,
    InvalidFlag,
    SampleFormatNotSupported,
    BadIODeviceCombination,
    InsufficientMemory,
    BufferTooBig,
    BufferTooSmall,
    NullCallback,
    BadStreamPtr,
    TimedOut,
    InternalError,
    DeviceUnavailable,
    IncompatibleHostApiSpecificStreamInfo,
    StreamIsStopped,
    StreamIsNotStopped,
    InputOverflowed,
    OutputUnderflowed,
    HostApiNotFound,
    InvalidHostApi,
    CanNotReadFromACallbackStream,
    CanNotWriteToACallbackStream,
    CanNotReadFromAnOutputOnlyStream,
    CanNotWriteToAnInputOnlyStream,
    IncompatibleStreamHostApi,
    BadBufferPtr,
};

pub fn fromPaError(code: binding.PaError) ?ErrorCode {
    return switch (code) {
        binding.paNoError => .no_error,
        binding.paNotInitialized => .not_initialized,
        binding.paUnanticipatedHostError => .unanticipated_host_error,
        binding.paInvalidChannelCount => .invalid_channel_count,
        binding.paInvalidSampleRate => .invalid_sample_rate,
        binding.paInvalidDevice => .invalid_device,
        binding.paInvalidFlag => .invalid_flag,
        binding.paSampleFormatNotSupported => .sample_format_not_supported,
        binding.paBadIODeviceCombination => .bad_io_device_combination,
        binding.paInsufficientMemory => .insufficient_memory,
        binding.paBufferTooBig => .buffer_too_big,
        binding.paBufferTooSmall => .buffer_too_small,
        binding.paNullCallback => .null_callback,
        binding.paBadStreamPtr => .bad_stream_ptr,
        binding.paTimedOut => .timed_out,
        binding.paInternalError => .internal_error,
        binding.paDeviceUnavailable => .device_unavailable,
        binding.paIncompatibleHostApiSpecificStreamInfo => .incompatible_host_api_specific_stream_info,
        binding.paStreamIsStopped => .stream_is_stopped,
        binding.paStreamIsNotStopped => .stream_is_not_stopped,
        binding.paInputOverflowed => .input_overflowed,
        binding.paOutputUnderflowed => .output_underflowed,
        binding.paHostApiNotFound => .host_api_not_found,
        binding.paInvalidHostApi => .invalid_host_api,
        binding.paCanNotReadFromACallbackStream => .can_not_read_from_a_callback_stream,
        binding.paCanNotWriteToACallbackStream => .can_not_write_to_a_callback_stream,
        binding.paCanNotReadFromAnOutputOnlyStream => .can_not_read_from_an_output_only_stream,
        binding.paCanNotWriteToAnInputOnlyStream => .can_not_write_to_an_input_only_stream,
        binding.paIncompatibleStreamHostApi => .incompatible_stream_host_api,
        binding.paBadBufferPtr => .bad_buffer_ptr,
        else => null,
    };
}

pub fn toErrorText(code: binding.PaError) [*:0]const u8 {
    return binding.Pa_GetErrorText(code);
}

pub fn toError(code: binding.PaError) ?Error {
    return switch (fromPaError(code) orelse return null) {
        .no_error => null,
        .not_initialized => Error.NotInitialized,
        .unanticipated_host_error => Error.UnanticipatedHostError,
        .invalid_channel_count => Error.InvalidChannelCount,
        .invalid_sample_rate => Error.InvalidSampleRate,
        .invalid_device => Error.InvalidDevice,
        .invalid_flag => Error.InvalidFlag,
        .sample_format_not_supported => Error.SampleFormatNotSupported,
        .bad_io_device_combination => Error.BadIODeviceCombination,
        .insufficient_memory => Error.InsufficientMemory,
        .buffer_too_big => Error.BufferTooBig,
        .buffer_too_small => Error.BufferTooSmall,
        .null_callback => Error.NullCallback,
        .bad_stream_ptr => Error.BadStreamPtr,
        .timed_out => Error.TimedOut,
        .internal_error => Error.InternalError,
        .device_unavailable => Error.DeviceUnavailable,
        .incompatible_host_api_specific_stream_info => Error.IncompatibleHostApiSpecificStreamInfo,
        .stream_is_stopped => Error.StreamIsStopped,
        .stream_is_not_stopped => Error.StreamIsNotStopped,
        .input_overflowed => Error.InputOverflowed,
        .output_underflowed => Error.OutputUnderflowed,
        .host_api_not_found => Error.HostApiNotFound,
        .invalid_host_api => Error.InvalidHostApi,
        .can_not_read_from_a_callback_stream => Error.CanNotReadFromACallbackStream,
        .can_not_write_to_a_callback_stream => Error.CanNotWriteToACallbackStream,
        .can_not_read_from_an_output_only_stream => Error.CanNotReadFromAnOutputOnlyStream,
        .can_not_write_to_an_input_only_stream => Error.CanNotWriteToAnInputOnlyStream,
        .incompatible_stream_host_api => Error.IncompatibleStreamHostApi,
        .bad_buffer_ptr => Error.BadBufferPtr,
    };
}

pub fn check(code: binding.PaError) Error!void {
    if (code == binding.paNoError or code == binding.paFormatIsSupported) return;
    return toError(code) orelse Error.InternalError;
}

pub fn checkedCount(code: c_int) Error!usize {
    if (code >= 0) return @intCast(code);
    try check(code);
    unreachable;
}

pub fn checkedAvailable(code: c_long) Error!usize {
    if (code >= 0) return @intCast(code);
    try check(@intCast(code));
    unreachable;
}

pub fn isOverflow(code: binding.PaError) bool {
    return code == binding.paInputOverflowed;
}

pub fn isUnderflow(code: binding.PaError) bool {
    return code == binding.paOutputUnderflowed;
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            mapsKnownNegativeCodes() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            returnsNullForUnknownCodes() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            classifiesOverflowAndUnderflow() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            checkAcceptsSuccessCodes() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            checkedCountAcceptsPositiveValues() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: glib.std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }

        fn mapsKnownNegativeCodes() !void {
            try grt.std.testing.expectEqual(ErrorCode.invalid_device, fromPaError(binding.paInvalidDevice).?);
            try grt.std.testing.expectEqual(ErrorCode.stream_is_stopped, fromPaError(binding.paStreamIsStopped).?);
            try grt.std.testing.expectEqual(Error.InvalidDevice, toError(binding.paInvalidDevice).?);
        }

        fn returnsNullForUnknownCodes() !void {
            try grt.std.testing.expectEqual(@as(?ErrorCode, null), fromPaError(-999_999));
        }

        fn classifiesOverflowAndUnderflow() !void {
            try grt.std.testing.expect(isOverflow(binding.paInputOverflowed));
            try grt.std.testing.expect(!isOverflow(binding.paOutputUnderflowed));
            try grt.std.testing.expect(isUnderflow(binding.paOutputUnderflowed));
        }

        fn checkAcceptsSuccessCodes() !void {
            try check(binding.paNoError);
            try check(binding.paFormatIsSupported);
        }

        fn checkedCountAcceptsPositiveValues() !void {
            try grt.std.testing.expectEqual(@as(usize, 4), try checkedCount(4));
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return glib.testing.TestRunner.make(Runner).new(&Holder.runner);
}
