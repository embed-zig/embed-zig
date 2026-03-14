const std = @import("std");
const testing = std.testing;
const module = @import("src.zig");
const test_exports = if (@hasDecl(module, "test_exports")) module.test_exports else struct {};
const c = module.c;
const Stream = module.Stream;
const DeviceIndex = module.DeviceIndex;
const HostApiIndex = module.HostApiIndex;
const Time = module.Time;
const SampleFormat = module.SampleFormat;
const StreamFlags = module.StreamFlags;
const StreamCallbackFlags = module.StreamCallbackFlags;
const StreamParameters = module.StreamParameters;
const StreamInfo = module.StreamInfo;
const DeviceInfo = module.DeviceInfo;
const HostApiInfo = module.HostApiInfo;
const HostErrorInfo = module.HostErrorInfo;
const Error = module.Error;
const check = module.check;
const getVersion = module.getVersion;
const getVersionText = module.getVersionText;
const initialize = module.initialize;
const terminate = module.terminate;
const getDeviceCount = module.getDeviceCount;
const getDefaultInputDevice = module.getDefaultInputDevice;
const getDefaultOutputDevice = module.getDefaultOutputDevice;
const getErrorText = module.getErrorText;
const AudioIO = module.AudioIO;

test "version metadata is available" {
    try std.testing.expect(getVersion() > 0);
    const text = std.mem.span(getVersionText());
    try std.testing.expect(text.len > 0);
}

test "known error maps to typed Zig error" {
    try std.testing.expectError(Error.InvalidDevice, check(c.paInvalidDevice));
}

test "error text is non-empty for known code" {
    const text = std.mem.span(getErrorText(c.paInvalidSampleRate));
    try std.testing.expect(text.len > 0);
}
