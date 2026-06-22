pub fn State(comptime ZuxAppType: type) type {
    return @FieldType(ZuxAppType.Store.Stores, "player").StateType;
}

pub fn Track(comptime ZuxAppType: type) type {
    return @FieldType(State(ZuxAppType), "selected");
}

pub fn make(comptime ZuxAppType: type) type {
    const TrackType = Track(ZuxAppType);

    return struct {
        pub fn durationMs(track: TrackType) u32 {
            const selected_song = song(track);
            return songDurationMs(selected_song.notes, selected_song.unit_ms);
        }

        pub fn fillChunk(track: TrackType, out: []i16, sample_rate: u32, start_ms: u32, loop_track: bool) void {
            if (sample_rate == 0) {
                @memset(out, 0);
                return;
            }

            const selected_song = song(track);
            fillFromSong(selected_song, out, sample_rate, start_ms, loop_track);
        }
    };
}

const Note = struct {
    frequency: u16,
    units: u8,
};

const Song = struct {
    notes: []const Note,
    unit_ms: u32,
    amplitude: i32,
};

const pcm_sample_rate: u32 = 16_000;

const c4: u16 = 262;
const d4: u16 = 294;
const e4: u16 = 330;
const f4: u16 = 349;
const g4: u16 = 392;
const a4: u16 = 440;
const b4: u16 = 494;
const c5: u16 = 523;
const d5: u16 = 587;
const e5: u16 = 659;
const f5: u16 = 698;
const g5: u16 = 784;

const rest: u16 = 0;

const twinkle = [_]Note{
    n(c4, 1), n(c4, 1), n(g4, 1), n(g4, 1), n(a4, 1), n(a4, 1), n(g4, 2),
    n(f4, 1), n(f4, 1), n(e4, 1), n(e4, 1), n(d4, 1), n(d4, 1), n(c4, 2),
    n(g4, 1), n(g4, 1), n(f4, 1), n(f4, 1), n(e4, 1), n(e4, 1), n(d4, 2),
    n(g4, 1), n(g4, 1), n(f4, 1), n(f4, 1), n(e4, 1), n(e4, 1), n(d4, 2),
    n(c4, 1), n(c4, 1), n(g4, 1), n(g4, 1), n(a4, 1), n(a4, 1), n(g4, 2),
    n(f4, 1), n(f4, 1), n(e4, 1), n(e4, 1), n(d4, 1), n(d4, 1), n(c4, 2),
};

const happy_birthday = [_]Note{
    n(g4, 1), n(g4, 1), n(a4, 2), n(g4, 2), n(c5, 2), n(b4, 4),
    n(g4, 1), n(g4, 1), n(a4, 2), n(g4, 2), n(d5, 2), n(c5, 4),
    n(g4, 1), n(g4, 1), n(g5, 2), n(e5, 2), n(c5, 2), n(b4, 2),
    n(a4, 4), n(f5, 1), n(f5, 1), n(e5, 2), n(c5, 2), n(d5, 2),
    n(c5, 4),
};

const doll_bear = [_]Note{
    n(c5, 1), n(e5, 1), n(g5, 1), n(e5, 1), n(c5, 1), n(rest, 1),
    n(d5, 1), n(f5, 1), n(a4, 1), n(f5, 1), n(d5, 1), n(rest, 1),
    n(e5, 1), n(g5, 1), n(c5, 1), n(g5, 1), n(e5, 2), n(d5, 1),
    n(f5, 1), n(b4, 1), n(f5, 1), n(d5, 2), n(c5, 1), n(e5, 1),
    n(g5, 1), n(c5, 1), n(g4, 2), n(a4, 1), n(g4, 1), n(e4, 1),
    n(g4, 1), n(c4, 4),
};

fn song(track: anytype) Song {
    return switch (track) {
        .twinkle => .{ .notes = &twinkle, .unit_ms = 300, .amplitude = 4800 },
        .happy_birthday => .{ .notes = &happy_birthday, .unit_ms = 280, .amplitude = 5000 },
        .doll_bear => .{ .notes = &doll_bear, .unit_ms = 240, .amplitude = 4600 },
    };
}

fn n(frequency: u16, units: u8) Note {
    return .{
        .frequency = frequency,
        .units = units,
    };
}

fn fillFromSong(song_data: Song, out: []i16, sample_rate: u32, start_ms: u32, loop_track: bool) void {
    const total_samples = songSampleCountRuntime(song_data.notes, song_data.unit_ms);
    if (total_samples == 0) {
        @memset(out, 0);
        return;
    }

    const start_sample = samplesFromMs(start_ms, pcm_sample_rate);
    for (out, 0..) |*sample, output_index| {
        var source_sample = start_sample + (@as(u64, @intCast(output_index)) * pcm_sample_rate) / sample_rate;
        if (source_sample >= total_samples) {
            if (!loop_track) {
                sample.* = 0;
                continue;
            }
            source_sample %= total_samples;
        }

        sample.* = sampleAt(song_data, source_sample);
    }
}

fn sampleAt(song_data: Song, source_sample: u64) i16 {
    var offset: u64 = 0;
    for (song_data.notes) |note| {
        const len = noteSampleCountRuntime(note, song_data.unit_ms);
        if (source_sample < offset + len) {
            return if (note.frequency == rest)
                0
            else
                synthNote(note.frequency, song_data.amplitude, pcm_sample_rate, source_sample - offset, len);
        }
        offset += len;
    }

    return 0;
}

fn songDurationMs(notes: []const Note, unit_ms: u32) u32 {
    var total: u32 = 0;
    for (notes) |note| total += @as(u32, note.units) * unit_ms;
    return total;
}

fn buildPcm(comptime notes: []const Note, comptime unit_ms: u32, comptime amplitude: i32) [songSampleCount(notes, unit_ms)]i16 {
    @setEvalBranchQuota(20_000_000);

    var out: [songSampleCount(notes, unit_ms)]i16 = undefined;
    var offset: usize = 0;
    inline for (notes) |note| {
        const len = noteSampleCount(note, unit_ms);
        var i: usize = 0;
        while (i < len) : (i += 1) {
            out[offset + i] = if (note.frequency == rest)
                0
            else
                synthNote(note.frequency, amplitude, pcm_sample_rate, i, len);
        }
        offset += len;
    }
    return out;
}

fn songSampleCount(comptime notes: []const Note, comptime unit_ms: u32) usize {
    var total: usize = 0;
    for (notes) |note| {
        total += noteSampleCount(note, unit_ms);
    }
    return total;
}

fn noteSampleCount(comptime note: Note, comptime unit_ms: u32) usize {
    return @intCast(samplesFromMs(@as(u32, note.units) * unit_ms, pcm_sample_rate));
}

fn songSampleCountRuntime(notes: []const Note, unit_ms: u32) u64 {
    var total: u64 = 0;
    for (notes) |note| total += noteSampleCountRuntime(note, unit_ms);
    return total;
}

fn noteSampleCountRuntime(note: Note, unit_ms: u32) u64 {
    return samplesFromMs(@as(u32, note.units) * unit_ms, pcm_sample_rate);
}

fn synthNote(frequency: u16, amplitude: i32, sample_rate: u32, position: u64, note_len: u64) i16 {
    const base = @as(u32, frequency);
    const wave =
        triangleWave(base, sample_rate, position) * 74 +
        triangleWave(base * 2, sample_rate, position) * 18 +
        triangleWave(base * 3, sample_rate, position) * 8;
    const env = envelopeScale(position, note_len, sample_rate);
    return clampSampleInt(@divTrunc(@as(i64, wave) * amplitude * env, 100 * 32767 * 1024));
}

fn triangleWave(frequency: u32, sample_rate: u32, position: u64) i32 {
    if (sample_rate == 0) return 0;

    const cycle = @as(u64, sample_rate);
    const half = cycle / 2;
    if (half == 0) return 0;

    const phase = (@as(u64, frequency) * position) % cycle;
    if (phase < half) {
        return -32767 + @as(i32, @intCast((phase * 65534) / half));
    }

    const tail = cycle - half;
    if (tail == 0) return 0;
    return 32767 - @as(i32, @intCast(((phase - half) * 65534) / tail));
}

fn envelopeScale(position: u64, note_len: u64, sample_rate: u32) i64 {
    const edge = @min(@min(note_len / 8, samplesFromMs(18, sample_rate)), note_len / 2);
    if (edge == 0) return 1024;
    if (position < edge) {
        return @intCast((position * 1024) / edge);
    }

    const remaining = note_len - position;
    if (remaining < edge) {
        return @intCast((remaining * 1024) / edge);
    }

    return 1024;
}

fn samplesFromMs(ms: u32, sample_rate: u32) u64 {
    return (@as(u64, ms) * @as(u64, sample_rate)) / 1000;
}

fn clampSampleInt(value: i64) i16 {
    if (value > 32767) return 32767;
    if (value < -32768) return -32768;
    return @intCast(value);
}
