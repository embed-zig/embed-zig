const glib = @import("glib");
const lvgl = @import("lvgl");

const controls = @import("../../controls.zig");
const Theme = @import("Theme.zig");
const TracksMod = @import("../player/Tracks.zig");

const UiAction = enum {
    play_pause,
    next,
    previous,
    volume_up,
    volume_down,
};

pub fn make(comptime ZuxAppType: type) type {
    const Tracks = TracksMod.make(ZuxAppType);
    const TrackType = TracksMod.Track(ZuxAppType);

    return struct {
        const Screen = @This();

        track_label: lvgl.Label,
        status_label: lvgl.Label,
        mic_button_obj: lvgl.Obj,
        volume_bar: lvgl.Bar,
        play_button_label: lvgl.Label,
        mic_button_label: lvgl.Label,
        track_text: [64:0]u8 = [_:0]u8{0} ** 64,
        status_text: [48:0]u8 = [_:0]u8{0} ** 48,
        last_selected: ?TrackType = null,
        last_playing: ?bool = null,
        last_recording: ?bool = null,
        last_gain_db: ?i8 = null,
        last_progress_pct: ?u8 = null,

        pub fn init(runtime: anytype, display: lvgl.Display) !Screen {
            var screen = display.activeScreen();
            screen.clean();
            screen.removeStyleAll();
            screen.setStyleBgColor(Theme.bg, Theme.selector_main);
            screen.setStyleBgOpa(lvgl.opa.cover, Theme.selector_main);

            var card = lvgl.Obj.create(&screen) orelse return error.OutOfMemory;
            card.removeStyleAll();
            card.setSize(284, 208);
            card.center();
            card.removeFlag(lvgl.object.Flags.scrollable);
            card.setStyleBgColor(Theme.panel, Theme.selector_main);
            card.setStyleBgOpa(lvgl.opa.cover, Theme.selector_main);
            card.setStyleRadius(10, Theme.selector_main);
            card.setStyleBorderWidth(0, Theme.selector_main);
            card.setStylePadAll(0, Theme.selector_main);

            var accent = lvgl.Obj.create(&card) orelse return error.OutOfMemory;
            accent.removeStyleAll();
            accent.setSize(284, 8);
            accent.alignTo(.top_left, 0, 0);
            accent.setStyleBgColor(Theme.accent, Theme.selector_main);
            accent.setStyleBgOpa(lvgl.opa.cover, Theme.selector_main);
            accent.setStyleBorderWidth(0, Theme.selector_main);

            var art = lvgl.Obj.create(&card) orelse return error.OutOfMemory;
            art.removeStyleAll();
            art.setSize(96, 96);
            art.alignTo(.top_left, 26, 24);
            art.setStyleBgColor(Theme.accent, Theme.selector_main);
            art.setStyleBgOpa(lvgl.opa.cover, Theme.selector_main);
            art.setStyleRadius(14, Theme.selector_main);
            art.setStyleBorderWidth(0, Theme.selector_main);

            var title = lvgl.Label.create(&card) orelse return error.OutOfMemory;
            title.asObj().alignTo(.top_left, 142, 34);
            title.asObj().setStyleTextColor(Theme.text, Theme.selector_main);

            var status = lvgl.Label.create(&card) orelse return error.OutOfMemory;
            status.asObj().alignTo(.top_left, 142, 64);
            status.asObj().setStyleTextColor(Theme.muted, Theme.selector_main);

            const mic_button = try createMicBadge(runtime, &card);

            var volume = lvgl.Bar.create(&card) orelse return error.OutOfMemory;
            volume.asObj().setSize(178, 8);
            volume.asObj().alignTo(.top_left, 26, 148);
            volume.asObj().setStyleBgColor(Theme.meter, Theme.selector_main);
            volume.asObj().setStyleBgOpa(lvgl.opa.cover, Theme.selector_main);
            volume.asObj().setStyleBgColor(Theme.text, Theme.selector_indicator);
            volume.asObj().setStyleBgOpa(lvgl.opa.cover, Theme.selector_indicator);
            volume.asObj().setStyleRadius(4, Theme.selector_main);
            volume.asObj().setStyleRadius(4, Theme.selector_indicator);
            volume.setRange(0, 100);

            _ = try createButton(runtime, &card, 30, "-", .volume_down, false);
            _ = try createButton(runtime, &card, 82, "<<", .previous, false);
            const play_button = try createButton(runtime, &card, 134, ">", .play_pause, true);
            _ = try createButton(runtime, &card, 186, ">>", .next, false);
            _ = try createButton(runtime, &card, 238, "+", .volume_up, false);

            return .{
                .track_label = title,
                .status_label = status,
                .mic_button_obj = mic_button.obj,
                .volume_bar = volume,
                .play_button_label = play_button,
                .mic_button_label = mic_button.label,
            };
        }

        pub fn setState(self: *Screen, player: anytype, playback: anytype, audio_system: anytype) void {
            const selected_changed = self.last_selected == null or self.last_selected.? != player.selected;
            const playing_changed = self.last_playing == null or self.last_playing.? != player.playing;
            const recording_changed = self.last_recording == null or self.last_recording.? != player.recording;
            const gain_changed = self.last_gain_db == null or self.last_gain_db.? != audio_system.gain_db;
            const progress_changed = self.last_progress_pct == null or self.last_progress_pct.? != playback.progress_pct;

            if (selected_changed) {
                self.setLabelText(&self.track_text, self.track_label, "{s}", .{Tracks.name(player.selected)});
                self.last_selected = player.selected;
            }

            if (playing_changed or gain_changed) {
                self.setLabelText(
                    &self.status_text,
                    self.status_label,
                    "{s} {d}dB",
                    .{ if (player.playing) "Playing" else "Paused", audio_system.gain_db },
                );
                self.last_gain_db = audio_system.gain_db;
            }

            if (progress_changed) {
                self.volume_bar.setValue(playback.progress_pct, false);
                self.last_progress_pct = playback.progress_pct;
            }

            if (playing_changed) {
                self.play_button_label.setTextStatic(if (player.playing) "||" else ">");
                self.last_playing = player.playing;
            }

            if (recording_changed) {
                self.mic_button_obj.setStyleBgColor(
                    if (player.recording) Theme.mic_active else Theme.meter,
                    Theme.selector_main,
                );
                self.mic_button_obj.setStyleBgColor(
                    if (player.recording) Theme.mic_active_pressed else Theme.control_pressed,
                    Theme.selector_pressed,
                );
                self.last_recording = player.recording;
            }
        }

        fn createButton(
            runtime: anytype,
            parent: *const lvgl.Obj,
            x: i32,
            text: [:0]const u8,
            action: UiAction,
            primary: bool,
        ) !lvgl.Label {
            var button = lvgl.Button.create(parent) orelse return error.OutOfMemory;
            try runtime.bindGroupedButton(button, .controls, controlButtonId(action));

            var button_obj = button.asObj();
            button_obj.removeStyleAll();
            button_obj.addFlag(lvgl.object.Flags.clickable);
            button_obj.setSize(40, 40);
            button_obj.alignTo(.top_left, x, 166);
            button_obj.setFlexFlow(.row);
            button_obj.setFlexAlign(.center, .center, .center);
            button_obj.setStyleRadius(0, Theme.selector_main);
            button_obj.setStyleRadius(0, Theme.selector_pressed);
            button_obj.setStyleBorderWidth(0, Theme.selector_main);
            button_obj.setStyleBorderWidth(0, Theme.selector_pressed);
            button_obj.setStyleOutlineWidth(0, Theme.selector_main);
            button_obj.setStyleOutlineWidth(0, Theme.selector_pressed);
            button_obj.setStylePadAll(0, Theme.selector_main);
            button_obj.setStylePadAll(0, Theme.selector_pressed);
            button_obj.setStyleBgOpa(lvgl.opa.cover, Theme.selector_main);
            button_obj.setStyleBgOpa(lvgl.opa.cover, Theme.selector_pressed);
            button_obj.setStyleBgColor(if (primary) Theme.accent else Theme.control, Theme.selector_main);
            button_obj.setStyleBgColor(if (primary) Theme.accent_pressed else Theme.control_pressed, Theme.selector_pressed);

            var label = button.createLabel() orelse return error.OutOfMemory;
            label.setTextStatic(text);
            var label_obj = label.asObj();
            label_obj.setStyleTextColor(if (primary) lvgl.Color.white() else Theme.text, Theme.selector_main);
            return label;
        }

        fn controlButtonId(action: UiAction) u32 {
            return switch (action) {
                .volume_down => controls.id(.volume_down),
                .previous => controls.id(.previous),
                .play_pause => controls.id(.front),
                .next => controls.id(.next),
                .volume_up => controls.id(.volume_up),
            };
        }

        const MicBadge = struct {
            obj: lvgl.Obj,
            label: lvgl.Label,
        };

        fn createMicBadge(runtime: anytype, parent: *const lvgl.Obj) !MicBadge {
            var button = lvgl.Button.create(parent) orelse return error.OutOfMemory;
            try runtime.bindSingleButton(button, .boot);

            var badge = button.asObj();
            badge.removeStyleAll();
            badge.addFlag(lvgl.object.Flags.clickable);
            badge.setSize(48, 20);
            badge.alignTo(.top_right, -16, 18);
            badge.setFlexFlow(.row);
            badge.setFlexAlign(.center, .center, .center);
            badge.setStyleBgColor(Theme.meter, Theme.selector_main);
            badge.setStyleBgColor(Theme.control_pressed, Theme.selector_pressed);
            badge.setStyleBgOpa(lvgl.opa.cover, Theme.selector_main);
            badge.setStyleBgOpa(lvgl.opa.cover, Theme.selector_pressed);
            badge.setStyleRadius(10, Theme.selector_main);
            badge.setStyleRadius(10, Theme.selector_pressed);
            badge.setStyleBorderWidth(0, Theme.selector_main);
            badge.setStyleBorderWidth(0, Theme.selector_pressed);
            badge.setStyleOutlineWidth(0, Theme.selector_main);
            badge.setStyleOutlineWidth(0, Theme.selector_pressed);
            badge.setStylePadAll(0, Theme.selector_main);
            badge.setStylePadAll(0, Theme.selector_pressed);

            var label = button.createLabel() orelse return error.OutOfMemory;
            label.setTextStatic("MIC");
            var label_obj = label.asObj();
            label_obj.setStyleTextColor(Theme.text, Theme.selector_main);

            return .{
                .obj = badge,
                .label = label,
            };
        }

        fn setLabelText(self: *Screen, buffer: anytype, label: lvgl.Label, comptime fmt: []const u8, args: anytype) void {
            _ = self;
            const text = glib.std.fmt.bufPrintZ(buffer, fmt, args) catch buffer[0..0 :0];
            label.setText(text);
        }
    };
}
