const binding = @import("binding.zig");
const build_options = @import("build_options");
const Device = @import("Device.zig");
const HostApi = @import("HostApi.zig");
const Stream = @import("Stream.zig");
const StreamParameters = @import("StreamParameters.zig");
const error_mod = @import("error.zig");
const types = @import("types.zig");

const Self = @This();

/// PortAudio manages process-global state under the C API; callers should treat
/// one `Self` value as the owner of a matching `Pa_Initialize`/`Pa_Terminate`
/// pair and serialize teardown accordingly.
initialized: bool = false,

pub fn init() error_mod.Error!Self {
    try error_mod.check(binding.Pa_Initialize());
    return .{ .initialized = true };
}

pub fn deinit(self: *Self) error_mod.Error!void {
    try self.terminate();
}

pub fn terminate(self: *Self) error_mod.Error!void {
    if (!self.initialized) return;
    // PortAudio expects callers to close owned streams before terminating the
    // process-global runtime.
    try error_mod.check(binding.Pa_Terminate());
    self.initialized = false;
}

pub fn version() c_int {
    return binding.Pa_GetVersion();
}

pub fn versionText() [*:0]const u8 {
    return binding.Pa_GetVersionText();
}

pub fn hostApiCount(self: Self) error_mod.Error!usize {
    _ = self;
    return try error_mod.checkedCount(binding.Pa_GetHostApiCount());
}

pub fn deviceCount(self: Self) error_mod.Error!usize {
    _ = self;
    return try error_mod.checkedCount(binding.Pa_GetDeviceCount());
}

pub fn defaultInputDevice(self: Self) error_mod.Error!?Device {
    const index = binding.Pa_GetDefaultInputDevice();
    if (index == binding.paNoDevice) return null;
    return try deviceInfo(self, index);
}

pub fn defaultOutputDevice(self: Self) error_mod.Error!?Device {
    const index = binding.Pa_GetDefaultOutputDevice();
    if (index == binding.paNoDevice) return null;
    return try deviceInfo(self, index);
}

pub fn defaultHostApi(self: Self) error_mod.Error!HostApi {
    const index = try error_mod.checkedCount(binding.Pa_GetDefaultHostApi());
    return try hostApiInfo(self, @intCast(index));
}

pub fn hostApiInfo(self: Self, index: types.HostApiIndex) error_mod.Error!HostApi {
    _ = self;
    const info = binding.Pa_GetHostApiInfo(index) orelse return error_mod.Error.InvalidHostApi;
    return HostApi.make(index, info);
}

pub fn deviceInfo(self: Self, index: types.DeviceIndex) error_mod.Error!Device {
    _ = self;
    const info = binding.Pa_GetDeviceInfo(index) orelse return error_mod.Error.InvalidDevice;
    return Device.make(index, info);
}

pub fn isFormatSupported(
    self: Self,
    input: ?StreamParameters,
    output: ?StreamParameters,
    sample_rate: f64,
) error_mod.Error!void {
    _ = self;
    if (input == null and output == null) return error_mod.Error.BadIODeviceCombination;
    var input_c: binding.PaStreamParameters = undefined;
    var output_c: binding.PaStreamParameters = undefined;
    const input_ptr = if (input) |value| blk: {
        input_c = value.toC();
        break :blk &input_c;
    } else null;
    const output_ptr = if (output) |value| blk: {
        output_c = value.toC();
        break :blk &output_c;
    } else null;

    try error_mod.check(binding.Pa_IsFormatSupported(input_ptr, output_ptr, sample_rate));
}

pub fn openInputStream(
    self: Self,
    params: StreamParameters,
    sample_rate: f64,
    frames_per_buffer: usize,
    flags: types.StreamFlags,
) error_mod.Error!Stream {
    return try openStream(self, params, null, sample_rate, frames_per_buffer, flags, .input);
}

pub fn openOutputStream(
    self: Self,
    params: StreamParameters,
    sample_rate: f64,
    frames_per_buffer: usize,
    flags: types.StreamFlags,
) error_mod.Error!Stream {
    return try openStream(self, null, params, sample_rate, frames_per_buffer, flags, .output);
}

fn openStream(
    self: Self,
    input: ?StreamParameters,
    output: ?StreamParameters,
    sample_rate: f64,
    frames_per_buffer: usize,
    flags: types.StreamFlags,
    mode: Stream.Mode,
) error_mod.Error!Stream {
    _ = self;
    var handle: ?*binding.PaStream = null;
    var input_c: binding.PaStreamParameters = undefined;
    var output_c: binding.PaStreamParameters = undefined;
    const input_ptr = if (input) |value| blk: {
        input_c = value.toC();
        break :blk &input_c;
    } else null;
    const output_ptr = if (output) |value| blk: {
        output_c = value.toC();
        break :blk &output_c;
    } else null;

    try error_mod.check(binding.Pa_OpenStream(
        &handle,
        input_ptr,
        output_ptr,
        sample_rate,
        @intCast(frames_per_buffer),
        flags,
        null,
        null,
    ));

    return Stream.make(
        handle.?,
        mode,
        if (input) |value| value.channel_count else output.?.channel_count,
    );
}

test "portaudio/unit_tests/portaudio/terminate_is_noop_when_uninitialized" {
    var portaudio: Self = .{};
    try portaudio.deinit();
}

test "portaudio/unit_tests/portaudio/rejects_empty_format_support_query" {
    const std = @import("std");
    var portaudio: Self = .{};

    try std.testing.expectError(
        error_mod.Error.BadIODeviceCombination,
        portaudio.isFormatSupported(null, null, 48_000),
    );
}

test "portaudio/integration_tests/portaudio/initializes_and_queries_metadata" {
    const std = @import("std");
    const testing = std.testing;
    if (!build_options.portaudio_live) return;

    var portaudio = try init();
    defer portaudio.deinit() catch @panic("portaudio terminate failed");

    try testing.expect(version() > 0);
    try testing.expect((try portaudio.hostApiCount()) > 0);
    try testing.expect((try portaudio.deviceCount()) >= 0);
}

test "portaudio/integration_tests/portaudio/default_device_queries_do_not_crash" {
    if (!build_options.portaudio_live) return;
    var portaudio = try init();
    defer portaudio.deinit() catch @panic("portaudio terminate failed");

    _ = try portaudio.defaultInputDevice();
    _ = try portaudio.defaultOutputDevice();
}

test "portaudio/integration_tests/portaudio/explicit_terminate_is_available" {
    if (!build_options.portaudio_live) return;
    var portaudio = try init();
    try portaudio.terminate();
    try portaudio.deinit();
}

test "portaudio/integration_tests/portaudio/default_host_api_query_succeeds" {
    const std = @import("std");
    const testing = std.testing;
    if (!build_options.portaudio_live) return;

    var portaudio = try init();
    defer portaudio.deinit() catch @panic("portaudio terminate failed");

    if (try portaudio.hostApiCount() == 0) return;

    const host_api = try portaudio.defaultHostApi();
    try testing.expect(host_api.name()[0] != 0);
}
