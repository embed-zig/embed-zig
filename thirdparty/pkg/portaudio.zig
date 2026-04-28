//! portaudio — PortAudio bindings and host-audio wrappers.
//!
//! Usage:
//!   const portaudio = @import("portaudio");

const types = @import("portaudio/src/types.zig");
const error_mod = @import("portaudio/src/error.zig");

pub const PortAudio = @import("portaudio/src/PortAudio.zig");
pub const HostApi = @import("portaudio/src/HostApi.zig");
pub const Device = @import("portaudio/src/Device.zig");
pub const Stream = @import("portaudio/src/Stream.zig");
pub const StreamParameters = @import("portaudio/src/StreamParameters.zig");
pub const DeviceIndex = types.DeviceIndex;
pub const HostApiIndex = types.HostApiIndex;
pub const Time = types.Time;
pub const SampleFormat = types.SampleFormat;
pub const StreamFlags = types.StreamFlags;

pub const Error = error_mod.Error;
pub const ErrorCode = error_mod.ErrorCode;
pub const fromPaError = error_mod.fromPaError;
pub const toError = error_mod.toError;
pub const checkError = error_mod.check;
pub const toErrorText = error_mod.toErrorText;
pub const isOverflow = error_mod.isOverflow;
pub const isUnderflow = error_mod.isUnderflow;

pub const test_runner = struct {
    pub const unit = @import("portaudio/test_runner/unit.zig");
    pub const integration = @import("portaudio/test_runner/integration.zig");
};
