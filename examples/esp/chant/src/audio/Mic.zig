const embed = @import("embed");
const esp = @import("esp");

const board = @import("../board.zig");

const log = esp.grt.std.log.scoped(.chant_mic);

pub const mic_count = 2;
pub const frame_samples_per_channel = 256;
pub const Mic = embed.audio.Mic.make(esp.grt, mic_count, frame_samples_per_channel);
const Error = embed.audio.Mic.Error;

const Impl = struct {
    gains_db: Mic.Gains = .{ null, null },
    logged_reads: u8 = 0,
    raw_ref: [frame_samples_per_channel]i16 = undefined,

    fn deinit(_: *Impl) void {}

    fn sampleRate(_: *Impl) u32 {
        return board.audio_sample_rate;
    }

    fn micCount(_: *Impl) u8 {
        return mic_count;
    }

    fn read(self: *Impl, frame: *Mic.Frame) Error!void {
        var offset: usize = 0;
        while (offset < frame.mic[0].len) {
            const n = board.readMicrophoneFrame(frame.mic[0][offset..], frame.mic[1][offset..], self.raw_ref[offset..]) catch |err| return fail("mic read", err);
            if (n == 0 or n > frame.mic[0].len - offset) return fail("mic short read", error.ShortMicRead);
            offset += n;
        }
        frame.ref = self.raw_ref;
        if (self.logged_reads < 3) {
            log.info("mic read output: {d} samples", .{offset});
            self.logged_reads += 1;
        }
    }

    fn gains(self: *Impl) Mic.Gains {
        return self.gains_db;
    }

    fn setGains(self: *Impl, gains_db: []const ?i8) Error!void {
        if (gains_db.len > mic_count) return error.Unsupported;
        if (gains_db.len == 0) return;
        var applied: ?i8 = null;
        for (gains_db, 0..) |gain_db, index| {
            if (gain_db) |value| {
                self.gains_db[index] = value;
                applied = value;
            }
        }
        if (applied) |gain_db| {
            board.setMicrophoneGain(gain_db) catch |err| return fail("mic set gain", err);
        }
    }

    fn enable(_: *Impl) Error!void {
        board.startMicrophoneCapture() catch |err| return fail("mic enable", err);
    }

    fn disable(_: *Impl) Error!void {
        board.stopMicrophoneCapture();
    }
};

var impl = Impl{};

pub fn driver() Mic {
    return Mic.init(&impl, &mic_vtable);
}

fn micDeinit(ptr: *anyopaque) void {
    const self: *Impl = @ptrCast(@alignCast(ptr));
    self.deinit();
}

fn micSampleRate(ptr: *anyopaque) u32 {
    const self: *Impl = @ptrCast(@alignCast(ptr));
    return self.sampleRate();
}

fn micCount(ptr: *anyopaque) u8 {
    const self: *Impl = @ptrCast(@alignCast(ptr));
    return self.micCount();
}

fn micRead(ptr: *anyopaque, frame: *Mic.Frame) Error!void {
    const self: *Impl = @ptrCast(@alignCast(ptr));
    return self.read(frame);
}

fn micGains(ptr: *anyopaque) Mic.Gains {
    const self: *Impl = @ptrCast(@alignCast(ptr));
    return self.gains();
}

fn micSetGains(ptr: *anyopaque, gains_db: []const ?i8) Error!void {
    const self: *Impl = @ptrCast(@alignCast(ptr));
    return self.setGains(gains_db);
}

fn micEnable(ptr: *anyopaque) Error!void {
    const self: *Impl = @ptrCast(@alignCast(ptr));
    return self.enable();
}

fn micDisable(ptr: *anyopaque) Error!void {
    const self: *Impl = @ptrCast(@alignCast(ptr));
    return self.disable();
}

const mic_vtable = Mic.VTable{
    .deinit = micDeinit,
    .sampleRate = micSampleRate,
    .micCount = micCount,
    .read = micRead,
    .gains = micGains,
    .setGains = micSetGains,
    .enable = micEnable,
    .disable = micDisable,
};

fn fail(name: []const u8, err: anyerror) Error {
    log.err("{s} failed: {s}", .{ name, @errorName(err) });
    return error.Unexpected;
}
