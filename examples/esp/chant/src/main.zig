const esp = @import("esp");
const lvgl = @import("lvgl");
const lvgl_osal = @import("lvgl_osal");
const opus_osal = @import("opus_osal");
const assets = @import("assets.zig");
const board = @import("board.zig");
const AudioMic = @import("audio/Mic.zig");
const AudioSpeaker = @import("audio/Speaker.zig");
const AudioSystem = @import("audio/AudioSystem.zig").Type;
const Player = @import("audio/Player.zig");
const Recoder = @import("audio/Recoder.zig");

const log = esp.grt.std.log.scoped(.chant_main);
const Thread = esp.grt.std.Thread;
const audio_allocator = esp.heap.Allocator(.{ .caps = .spiram_8bit, .alignment = .align_u32 });
const thread_allocator = esp.heap.Allocator(.{ .caps = .internal_8bit, .alignment = .align_u32 });
const audio_read_thread_stack_size = 16 * 1024;
const audio_write_thread_stack_size = 8 * 1024;
const default_volume: u8 = 0xb0;
const maximum_volume: u8 = 0xc6;
const volume_step: u8 = 0x02;
const poll_interval_ms: u32 = 20;
const opus_exports = opus_osal.make(esp.grt, esp.heap.Allocator(.{
    .caps = .spiram_8bit,
    .alignment = .align_u32,
}));
const lvgl_exports = lvgl_osal.makeWithAllocators(
    esp.grt,
    esp.heap.Allocator(.{ .caps = .internal_8bit }),
    esp.heap.Allocator(.{ .caps = .spiram_8bit, .alignment = .align_u32 }),
);

comptime {
    _ = opus_exports.opus_alloc_scratch;
    _ = lvgl_exports.lv_mutex_init;
    _ = lvgl_exports.lv_mutex_lock;
    _ = lvgl_exports.lv_mutex_lock_isr;
    _ = lvgl_exports.lv_mutex_unlock;
    _ = lvgl_exports.lv_mutex_delete;
    _ = lvgl_exports.lv_thread_sync_init;
    _ = lvgl_exports.lv_thread_sync_wait;
    _ = lvgl_exports.lv_thread_sync_signal;
    _ = lvgl_exports.lv_thread_sync_signal_isr;
    _ = lvgl_exports.lv_thread_sync_delete;
    _ = lvgl_exports.lv_thread_init;
    _ = lvgl_exports.lv_thread_delete;
    _ = lvgl_exports.lv_mem_init;
    _ = lvgl_exports.lv_mem_deinit;
    _ = lvgl_exports.lv_mem_add_pool;
    _ = lvgl_exports.lv_mem_remove_pool;
    _ = lvgl_exports.lv_malloc_core;
    _ = lvgl_exports.lv_realloc_core;
    _ = lvgl_exports.lv_free_core;
    _ = lvgl_exports.lv_mem_monitor_core;
    _ = lvgl_exports.lv_mem_test_core;
}

pub export fn zig_esp_main() void {
    board.initNvs() catch |err| fail("nvs", err);
    board.mountStorage() catch |err| fail("spiffs mount", err);
    defer board.unmountStorage();

    const info = board.storageInfo() catch |err| fail("spiffs info", err);
    log.info("spiffs total={d} used={d}", .{ info.total, info.used });

    board.initBoard() catch |err| fail("board init", err);
    lvgl.init();
    board.initAudio() catch |err| fail("audio init", err);
    board.initButton() catch |err| fail("button init", err);
    log.info("board initialized; tracks={d}", .{assets.tracks.len});

    var system = AudioSystem.init(audio_allocator, .{
        .read_thread = .{
            .stack_size = audio_read_thread_stack_size,
            .name = "audio_read",
            .allocator = thread_allocator,
            .core_id = 0,
        },
        .write_thread = .{
            .stack_size = audio_write_thread_stack_size,
            .name = "audio_write",
            .allocator = thread_allocator,
            .core_id = 1,
        },
    }) catch |err| fail("audio system init", err);
    system.setMic(AudioMic.driver()) catch |err| fail("audio system mic", err);
    system.setSpeaker(AudioSpeaker.driver()) catch |err| fail("audio system speaker", err);

    var player = Player.init(audio_allocator, &system) catch |err| fail("music player", err);
    var recoder = Recoder.init(audio_allocator, &system) catch |err| fail("mic recoder", err);

    system.start() catch |err| fail("audio system start", err);
    player.startThread() catch |err| fail("music player start", err);
    recoder.startThread() catch |err| fail("mic recoder start", err);

    runControlLoop(&system, &player, &recoder);
}

fn runControlLoop(system: *AudioSystem, player: *Player, recoder: *Recoder) noreturn {
    var volume = default_volume;
    var mic_pressed = false;
    var shown_track: ?board.Track = null;
    var shown_playing: ?bool = null;
    var shown_mic_active: ?bool = null;
    var shown_volume: ?u8 = null;

    system.setSpkGain(volumeToGainDb(volume)) catch |err| {
        log.warn("initial volume failed: {s}", .{@errorName(err)});
    };

    while (true) {
        board.tickDisplay(poll_interval_ms);
        switch (board.takeDisplayAction()) {
            .none => {},
            .play_pause => player.togglePlay(),
            .next => player.next(),
            .previous => player.previous(),
            .volume_up => {
                volume = if (volume > maximum_volume - volume_step) maximum_volume else volume + volume_step;
                system.setSpkGain(volumeToGainDb(volume)) catch |err| {
                    log.warn("volume up failed: {s}", .{@errorName(err)});
                };
            },
            .volume_down => {
                volume = if (volume < volume_step) 0 else volume - volume_step;
                system.setSpkGain(volumeToGainDb(volume)) catch |err| {
                    log.warn("volume down failed: {s}", .{@errorName(err)});
                };
            },
            .mic => {},
        }

        const pressed = board.buttonPressedRaw();
        if (pressed and !mic_pressed) {
            mic_pressed = true;
            recoder.start();
        } else if (!pressed and mic_pressed) {
            mic_pressed = false;
            recoder.stop();
        }

        const track = player.currentTrack();
        const playing = player.isPlaying();
        const mic_active = mic_pressed;
        if (shown_track != track.id or
            shown_playing != playing or
            shown_mic_active != mic_active or
            shown_volume != volume)
        {
            board.showPlayer(track.id, if (mic_active) .microphone else .music, playing, volume) catch |err| {
                log.warn("display update failed: {s}", .{@errorName(err)});
                Thread.sleep(@as(u64, poll_interval_ms) * esp.grt.time.duration.MilliSecond);
                continue;
            };
            shown_track = track.id;
            shown_playing = playing;
            shown_mic_active = mic_active;
            shown_volume = volume;
        }
        Thread.sleep(@as(u64, poll_interval_ms) * esp.grt.time.duration.MilliSecond);
    }
}

fn volumeToGainDb(volume: u8) i8 {
    return @intCast(@divTrunc(@as(i16, @intCast(volume)), 2) - 96);
}

fn fail(name: []const u8, err: anyerror) noreturn {
    log.err("{s} failed: {s}", .{ name, @errorName(err) });
    @panic("chant init failed");
}
