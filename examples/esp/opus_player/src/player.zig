const esp = @import("esp");
const assets = @import("assets.zig");
const board = @import("board.zig");
const opus_ogg = @import("opus_ogg.zig");

const log = esp.grt.std.log.scoped(.opus_player);
const Thread = esp.grt.std.Thread;

const ns_per_ms: u64 = 1_000_000;

var button_latched = false;

pub fn run() noreturn {
    var current: usize = 0;

    while (true) {
        const track = assets.tracks[current];
        board.showTrack(track.id) catch |err| {
            log.warn("display update failed: {s}", .{@errorName(err)});
        };
        log.info("playing {s} from {s}", .{ track.name, track.path });

        const result = opus_ogg.play(track.path, pollNextRequest) catch |err| recover: {
            log.err("playback failed for {s}: {s}", .{ track.name, @errorName(err) });
            sleepMs(1000);
            break :recover .ended;
        };

        switch (result) {
            .switched => {
                current = nextIndex(current);
                continue;
            },
            .ended => {},
        }

        if (waitBetweenLoops()) {
            current = nextIndex(current);
        }
    }
}

fn waitBetweenLoops() bool {
    var elapsed: u32 = 0;
    while (elapsed < 2000) : (elapsed += 20) {
        if (pollNextRequest()) return true;
        sleepMs(20);
    }
    return false;
}

fn nextIndex(current: usize) usize {
    return (current + 1) % assets.tracks.len;
}

fn pollNextRequest() bool {
    const pressed = board.buttonPressedRaw();
    if (!pressed) {
        button_latched = false;
        return false;
    }
    if (button_latched) return false;
    button_latched = true;
    return true;
}

fn sleepMs(ms: u32) void {
    Thread.sleep(@as(u64, ms) * ns_per_ms);
}
