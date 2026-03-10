//! Unified audio system HAL contract.
//!
//! Models mic capture + speaker-reference + speaker output as a single
//! coordinated subsystem.  The driver owns the entire audio pipeline:
//!
//!   - `readFrame` returns all mic channels **and** a mandatory ref channel.
//!   - `writeSpk` pushes samples to the speaker.
//!   - Per-mic gain is set via `setMicGain(index, dB)`.
//!   - Speaker gain is set via `setSpkGain(dB)`; the driver automatically
//!     derives the ref gain from the speaker gain.
//!   - Ref-to-mic time alignment is the driver's responsibility.

const std = @import("std");
const hal_marker = @import("marker.zig");

pub const Error = error{
    WouldBlock,
    Timeout,
    Overflow,
    InvalidState,
    AudioSystemError,
};

pub const Config = struct {
    sample_rate: u32 = 16000,
    mic_count: u8 = 1,
};

pub fn Frame(comptime mic_count: u8) type {
    return struct {
        mic: [mic_count][]const i16,
        ref: []const i16,
    };
}

pub fn is(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (!@hasDecl(T, "_hal_marker")) return false;
    const marker = T._hal_marker;
    if (@TypeOf(marker) != hal_marker.Marker) return false;
    return marker.kind == .audio_system;
}

/// spec must define:
///   - Driver          — concrete driver type
///   - meta.id         — []const u8 identifier
///   - config          — Config (sample_rate > 0, mic_count > 0)
///
/// Driver must implement:
///   - readFrame(*Driver) Error!Frame(config.mic_count)
///   - writeSpk(*Driver, []const i16) Error!usize
///   - setMicGain(*Driver, u8, i8) Error!void
///   - setSpkGain(*Driver, i8) Error!void
///   - start(*Driver) Error!void
///   - stop(*Driver) Error!void
pub fn from(comptime spec: type) type {
    const BaseDriver = comptime switch (@typeInfo(spec.Driver)) {
        .pointer => |p| p.child,
        else => spec.Driver,
    };

    const cfg: Config = comptime if (@hasDecl(spec, "config")) spec.config else .{};
    const FrameType = Frame(cfg.mic_count);

    comptime {
        if (cfg.sample_rate == 0) {
            @compileError("audio_system config.sample_rate must be > 0");
        }
        if (cfg.mic_count == 0) {
            @compileError("audio_system config.mic_count must be > 0");
        }

        _ = @as(*const fn (*BaseDriver) Error!FrameType, &BaseDriver.readFrame);
        _ = @as(*const fn (*BaseDriver, []const i16) Error!usize, &BaseDriver.writeSpk);
        _ = @as(*const fn (*BaseDriver, u8, i8) Error!void, &BaseDriver.setMicGain);
        _ = @as(*const fn (*BaseDriver, i8) Error!void, &BaseDriver.setSpkGain);
        _ = @as(*const fn (*BaseDriver) Error!void, &BaseDriver.start);
        _ = @as(*const fn (*BaseDriver) Error!void, &BaseDriver.stop);

        _ = @as([]const u8, spec.meta.id);
    }

    const Driver = spec.Driver;
    return struct {
        const Self = @This();

        pub const _hal_marker: hal_marker.Marker = .{
            .kind = .audio_system,
            .id = spec.meta.id,
        };
        pub const DriverType = Driver;
        pub const meta = spec.meta;
        pub const config: Config = cfg;
        pub const FrameT = FrameType;

        driver: *Driver,

        pub fn init(driver: *Driver) Self {
            return .{ .driver = driver };
        }

        pub fn readFrame(self: *Self) Error!FrameT {
            return self.driver.readFrame();
        }

        pub fn writeSpk(self: *Self, buffer: []const i16) Error!usize {
            return self.driver.writeSpk(buffer);
        }

        pub fn setMicGain(self: *Self, mic_index: u8, gain_db: i8) Error!void {
            return self.driver.setMicGain(mic_index, gain_db);
        }

        pub fn setSpkGain(self: *Self, gain_db: i8) Error!void {
            return self.driver.setSpkGain(gain_db);
        }

        pub fn start(self: *Self) Error!void {
            return self.driver.start();
        }

        pub fn stop(self: *Self) Error!void {
            return self.driver.stop();
        }

        pub fn samplesForMs(duration_ms: u32) u32 {
            return cfg.sample_rate * duration_ms / 1000;
        }

        pub fn msForSamples(samples: u32) u32 {
            return samples * 1000 / cfg.sample_rate;
        }
    };
}

test "audio_system wrapper" {
    const mic_count = 2;
    const FrameType = Frame(mic_count);

    const MockDriver = struct {
        mic_buf: [mic_count][4]i16 = .{
            .{ 10, 20, 30, 40 },
            .{ 50, 60, 70, 80 },
        },
        ref_buf: [4]i16 = .{ 1, 2, 3, 4 },
        wrote: usize = 0,
        mic_gains: [mic_count]i8 = .{ 0, 0 },
        spk_gain: i8 = 0,

        pub fn init() !@This() {
            return .{};
        }

        pub fn deinit(_: *@This()) void {}

        pub fn readFrame(self: *@This()) Error!FrameType {
            return .{
                .mic = .{ &self.mic_buf[0], &self.mic_buf[1] },
                .ref = &self.ref_buf,
            };
        }

        pub fn writeSpk(self: *@This(), buffer: []const i16) Error!usize {
            self.wrote += buffer.len;
            return buffer.len;
        }

        pub fn setMicGain(self: *@This(), index: u8, gain_db: i8) Error!void {
            if (index >= mic_count) return error.InvalidState;
            self.mic_gains[index] = gain_db;
        }

        pub fn setSpkGain(self: *@This(), gain_db: i8) Error!void {
            self.spk_gain = gain_db;
        }

        pub fn start(_: *@This()) Error!void {}
        pub fn stop(_: *@This()) Error!void {}
    };

    const AudioSystem = from(struct {
        pub const Driver = MockDriver;
        pub const meta = .{ .id = "audio_system.test" };
        pub const config = Config{ .sample_rate = 16000, .mic_count = mic_count };
    });

    var d = try MockDriver.init();
    var sys = AudioSystem.init(&d);

    const frame = try sys.readFrame();
    try std.testing.expectEqual(@as(i16, 10), frame.mic[0][0]);
    try std.testing.expectEqual(@as(i16, 50), frame.mic[1][0]);
    try std.testing.expectEqual(@as(i16, 1), frame.ref[0]);

    _ = try sys.writeSpk(&[_]i16{ 100, 200 });
    try std.testing.expectEqual(@as(usize, 2), d.wrote);

    try sys.setMicGain(0, 12);
    try sys.setMicGain(1, -6);
    try std.testing.expectEqual(@as(i8, 12), d.mic_gains[0]);
    try std.testing.expectEqual(@as(i8, -6), d.mic_gains[1]);

    try sys.setSpkGain(3);
    try std.testing.expectEqual(@as(i8, 3), d.spk_gain);

    try std.testing.expect(is(AudioSystem));
    try std.testing.expectEqual(@as(u32, 160), AudioSystem.samplesForMs(10));
    try std.testing.expectEqual(@as(u32, 10), AudioSystem.msForSamples(160));
}
