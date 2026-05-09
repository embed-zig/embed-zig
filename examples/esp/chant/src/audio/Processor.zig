const embed = @import("embed");
const esp = @import("esp");

const board = @import("../board.zig");
const AudioMic = @import("Mic.zig");

const log = esp.grt.std.log.scoped(.chant_processor);
const Error = embed.audio.AudioSystem.Error;

var logged_outputs: u8 = 0;

pub fn process(frame: AudioMic.Mic.Frame, out: []i16) Error!usize {
    const ref = frame.ref orelse return error.InvalidState;
    const n = board.processAfeFrame(frame.mic[0][0..], frame.mic[1][0..], ref[0..], out) catch |err| {
        return fail("afe process", err);
    };
    applyMonitorGain(out[0..n]);
    if (n > 0 and logged_outputs < 3) {
        log.info("afe process output: {d} samples mic_peak={d} ref_peak={d}", .{
            n,
            peakAbs(frame.mic[0][0..]),
            peakAbs(ref[0..]),
        });
        logged_outputs += 1;
    }
    return n;
}

fn applyMonitorGain(samples: []i16) void {
    for (samples) |*sample| {
        const value = @as(i32, sample.*) * 3;
        if (value > 32767) {
            sample.* = 32767;
        } else if (value < -32768) {
            sample.* = -32768;
        } else {
            sample.* = @intCast(value);
        }
    }
}

fn peakAbs(samples: []const i16) i16 {
    var peak: i16 = 0;
    for (samples) |sample| {
        const value = if (sample == -32768) @as(i16, 32767) else if (sample < 0) -sample else sample;
        if (value > peak) peak = value;
    }
    return peak;
}

fn fail(name: []const u8, err: anyerror) Error {
    log.err("{s} failed: {s}", .{ name, @errorName(err) });
    return error.Unexpected;
}
