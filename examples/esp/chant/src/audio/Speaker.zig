const embed = @import("embed");
const esp = @import("esp");

const board = @import("../board.zig");

const log = esp.grt.std.log.scoped(.chant_speaker);

pub const frame_samples_per_channel = 256;
pub const Speaker = embed.audio.Speaker.make(esp.grt, frame_samples_per_channel);
const Error = Speaker.Error;

const Impl = struct {
    gain_db: ?i8 = null,
    logged_writes: u8 = 0,

    fn deinit(_: *Impl) void {}

    fn sampleRate(_: *Impl) u32 {
        return board.audio_sample_rate;
    }

    fn write(self: *Impl, frame: []const i16) Error!usize {
        if (frame.len == 0) return 0;
        board.initAudio() catch |err| return fail("speaker init", err);
        board.writePcm(frame) catch |err| return fail("speaker write", err);
        if (self.logged_writes < 3) {
            log.info("speaker wrote {d} samples", .{frame.len});
            self.logged_writes += 1;
        }
        return frame.len;
    }

    fn gain(self: *Impl) ?i8 {
        return self.gain_db;
    }

    fn setGain(self: *Impl, gain_db: i8) Error!void {
        board.setVolume(gainDbToVolume(gain_db)) catch |err| return fail("speaker set gain", err);
        self.gain_db = gain_db;
    }

    fn enable(_: *Impl) Error!void {
        board.setSpeakerEnabled(true) catch |err| return fail("speaker enable", err);
    }

    fn disable(_: *Impl) Error!void {
        board.setSpeakerEnabled(false) catch |err| return fail("speaker disable", err);
    }
};

var impl = Impl{};

pub fn driver() Speaker {
    return Speaker.init(&impl, &speaker_vtable);
}

fn speakerDeinit(ptr: *anyopaque) void {
    const self: *Impl = @ptrCast(@alignCast(ptr));
    self.deinit();
}

fn speakerSampleRate(ptr: *anyopaque) u32 {
    const self: *Impl = @ptrCast(@alignCast(ptr));
    return self.sampleRate();
}

fn speakerWrite(ptr: *anyopaque, frame: []const i16) Error!usize {
    const self: *Impl = @ptrCast(@alignCast(ptr));
    return self.write(frame);
}

fn speakerGain(ptr: *anyopaque) ?i8 {
    const self: *Impl = @ptrCast(@alignCast(ptr));
    return self.gain();
}

fn speakerSetGain(ptr: *anyopaque, gain_db: i8) Error!void {
    const self: *Impl = @ptrCast(@alignCast(ptr));
    return self.setGain(gain_db);
}

fn speakerEnable(ptr: *anyopaque) Error!void {
    const self: *Impl = @ptrCast(@alignCast(ptr));
    return self.enable();
}

fn speakerDisable(ptr: *anyopaque) Error!void {
    const self: *Impl = @ptrCast(@alignCast(ptr));
    return self.disable();
}

const speaker_vtable = Speaker.VTable{
    .deinit = speakerDeinit,
    .sampleRate = speakerSampleRate,
    .write = speakerWrite,
    .gain = speakerGain,
    .setGain = speakerSetGain,
    .enable = speakerEnable,
    .disable = speakerDisable,
};

fn fail(name: []const u8, err: anyerror) Error {
    log.err("{s} failed: {s}", .{ name, @errorName(err) });
    return error.Unexpected;
}

fn gainDbToVolume(gain_db: i8) u8 {
    const scaled: i16 = (@as(i16, gain_db) + 96) * 2;
    if (scaled <= 0) return 0;
    if (scaled >= 255) return 255;
    return @intCast(scaled);
}

fn volumeToGainDb(volume: u8) i8 {
    return @intCast(@divTrunc(@as(i16, @intCast(volume)), 2) - 96);
}
