const embed = @import("embed");
const esp = @import("esp");
const glib = @import("glib");
const lvgl = @import("lvgl");

const Ctrl = @This();
const DisplayApi = embed.drivers.Display;
const Rgb = DisplayApi.Rgb;
const Thread = esp.grt.std.Thread;
const AtomicBool = esp.grt.std.atomic.Value(bool);
const EventChannel = esp.grt.sync.Channel(Action);

const thread_allocator = esp.heap.Allocator(.{ .caps = .internal_8bit, .alignment = .align_u32 });
const width_px: u16 = 320;
const height_px: u16 = 240;
const draw_rows: u16 = 20;
const max_draw_pixels = @as(usize, width_px) * @as(usize, draw_rows);
const rgb888_bytes_per_pixel = 3;
const max_draw_bytes = max_draw_pixels * rgb888_bytes_per_pixel;
const title_buffer_len = 64;
const volume_text_buffer_len = 16;
const selector_main = lvgl.binding.LV_PART_MAIN;
const selector_indicator = lvgl.binding.LV_PART_INDICATOR;
const selector_pressed = lvgl.binding.LV_PART_MAIN | lvgl.binding.LV_STATE_PRESSED;
const render_tick_ms: u32 = 20;
const default_event_capacity: usize = 16;

pub const Track = enum(c_int) {
    twinkle = 0,
    happy_birthday = 1,
    doll_bear = 2,
};

pub const Action = enum {
    none,
    play_pause,
    mic,
    next,
    previous,
    volume_up,
    volume_down,
};

pub const Mode = enum {
    music,
    microphone,
};

pub const TouchPoint = struct {
    x: u16,
    y: u16,
};

pub const TouchReader = *const fn () ?TouchPoint;

pub const RenderThreadConfig = struct {
    spawn: Thread.SpawnConfig = .{
        .name = "ui_render",
        .stack_size = 8 * 1024,
        .allocator = thread_allocator,
    },
};

const UiObjects = struct {
    title: lvgl.Label,
    status: lvgl.Label,
    play_label: lvgl.Label,
    mic_badge: lvgl.Obj,
    volume: lvgl.Bar,
    volume_text: lvgl.Label,
};

const ButtonBinding = struct {
    ctrl: ?*Ctrl = null,
    action: Action,
};

const StringSubject = struct {
    owner: ?*Ctrl = null,
    buffer: *[title_buffer_len:0]u8,
    previous_buffer: *[title_buffer_len:0]u8,

    fn init(owner: *Ctrl, buffer: *[title_buffer_len:0]u8, previous_buffer: *[title_buffer_len:0]u8, initial_value: [:0]const u8) StringSubject {
        var self = StringSubject{
            .owner = owner,
            .buffer = buffer,
            .previous_buffer = previous_buffer,
        };
        self.copyString(initial_value);
        return self;
    }

    fn copyString(self: *StringSubject, value: [:0]const u8) void {
        if (glib.std.mem.eql(u8, self.getString(), value)) return;
        @memcpy(self.previous_buffer[0..], self.buffer[0..]);
        copyZ(self.buffer, value);
        if (self.owner) |owner| owner.renderState();
    }

    fn getString(self: *const StringSubject) [:0]const u8 {
        return self.buffer[0.. :0];
    }
};

const IntSubject = struct {
    owner: ?*Ctrl = null,
    value: i32,
    previous_value: i32,
    min_value: i32 = -2147483648,
    max_value: i32 = 2147483647,

    fn init(owner: *Ctrl, value: i32) IntSubject {
        return .{
            .owner = owner,
            .value = value,
            .previous_value = value,
        };
    }

    fn setInt(self: *IntSubject, value: i32) void {
        const next_value = clampI32(value, self.min_value, self.max_value);
        if (self.value == next_value) return;
        self.previous_value = self.value;
        self.value = next_value;
        if (self.owner) |owner| owner.renderState();
    }

    fn getInt(self: *const IntSubject) i32 {
        return self.value;
    }

    fn setMinInt(self: *IntSubject, value: i32) void {
        self.min_value = value;
        self.value = clampI32(self.value, self.min_value, self.max_value);
    }

    fn setMaxInt(self: *IntSubject, value: i32) void {
        self.max_value = value;
        self.value = clampI32(self.value, self.min_value, self.max_value);
    }
};

display: DisplayApi = undefined,
display_ready: bool = false,
lv_display: ?lvgl.Display = null,
lv_indev: ?lvgl.Indev = null,
ui_ready: bool = false,
ui_objects: ?UiObjects = null,
draw_buffer: [max_draw_bytes]u8 align(64) = undefined,
flush_buffer: [max_draw_pixels]Rgb = undefined,
touch_reader: ?TouchReader = null,
last_touch: TouchPoint = .{ .x = 0, .y = 0 },

track: Track = .twinkle,
playing: bool = true,
mic_active: bool = false,
volume_value: u8 = 0xb0,

track_name_buffer: [title_buffer_len:0]u8 = [_:0]u8{0} ** title_buffer_len,
track_name_previous_buffer: [title_buffer_len:0]u8 = [_:0]u8{0} ** title_buffer_len,
volume_text_buffer: [volume_text_buffer_len:0]u8 = [_:0]u8{0} ** volume_text_buffer_len,
track_name_subject: ?StringSubject = null,
playing_subject: ?IntSubject = null,
mic_active_subject: ?IntSubject = null,
volume_subject: ?IntSubject = null,

event_channel: ?EventChannel = null,
pending_action: Action = .none,
render_thread: ?Thread = null,
render_stop: AtomicBool = AtomicBool.init(false),

volume_down_binding: ButtonBinding = .{ .action = .volume_down },
previous_binding: ButtonBinding = .{ .action = .previous },
play_pause_binding: ButtonBinding = .{ .action = .play_pause },
next_binding: ButtonBinding = .{ .action = .next },
volume_up_binding: ButtonBinding = .{ .action = .volume_up },

var default_ctrl = Ctrl{};
var active_ctrl: ?*Ctrl = null;

pub fn init() Ctrl {
    return .{};
}

pub fn deinit(self: *Ctrl) void {
    self.stopRenderThread();
    self.deinitSubjects();
    if (self.event_channel) |*channel| {
        channel.close();
        channel.deinit();
        self.event_channel = null;
    }
    if (active_ctrl == self) active_ctrl = null;
}

pub fn attachTouchReader(self: *Ctrl, reader: TouchReader) void {
    self.touch_reader = reader;
}

pub fn ensure(self: *Ctrl, display: DisplayApi) !void {
    if (!lvgl.isInitialized()) {
        lvgl.init();
    }
    lvgl.binding.lv_lock();
    defer lvgl.binding.lv_unlock();
    try self.ensureLocked(display);
}

fn ensureLocked(self: *Ctrl, display: DisplayApi) !void {
    active_ctrl = self;
    self.display = display;
    self.display_ready = true;

    self.ensureSubjects();
    if (self.ui_ready) return;

    var created_display = lvgl.Display.create(width_px, height_px) orelse return error.OutOfMemory;
    created_display.setColorFormat(lvgl.binding.LV_COLOR_FORMAT_RGB888);
    created_display.setBuffers(
        @ptrCast(self.draw_buffer[0..].ptr),
        null,
        @intCast(self.draw_buffer.len),
        lvgl.binding.LV_DISPLAY_RENDER_MODE_PARTIAL,
    );
    created_display.setFlushCb(flushCb);
    created_display.setDefault();
    self.lv_display = created_display;

    var created_indev = lvgl.Indev.create() orelse return error.OutOfMemory;
    created_indev.setDisplay(&created_display);
    created_indev.setType(.pointer);
    created_indev.setReadCb(touchReadCb);
    self.lv_indev = created_indev;

    try self.createObjects(&created_display);
    self.renderState();
    self.ui_ready = true;
}

pub fn showState(self: *Ctrl, display: DisplayApi, track: Track, mode: Mode, playing: bool, volume: u8) !void {
    if (!lvgl.isInitialized()) {
        lvgl.init();
    }
    lvgl.binding.lv_lock();
    defer lvgl.binding.lv_unlock();

    try self.ensureLocked(display);
    self.setTrack(track);
    self.setPlaying(playing);
    self.setMicActive(mode == .microphone);
    self.setVolume(volume);
    self.renderTickLocked(1);
}

pub fn setTrack(self: *Ctrl, track: Track) void {
    self.track = track;
    self.setTrackName(trackTitle(track));
}

pub fn setTrackName(self: *Ctrl, name: [:0]const u8) void {
    if (self.track_name_subject) |*subject| {
        subject.copyString(name);
    }
}

pub fn setPlaying(self: *Ctrl, playing: bool) void {
    self.playing = playing;
    if (self.playing_subject) |*subject| {
        subject.setInt(boolInt(playing));
    }
}

pub fn setMicActive(self: *Ctrl, active: bool) void {
    self.mic_active = active;
    if (self.mic_active_subject) |*subject| {
        subject.setInt(boolInt(active));
    }
}

pub fn setVolume(self: *Ctrl, volume: u8) void {
    self.volume_value = volume;
    if (self.volume_subject) |*subject| {
        subject.setInt(volume);
    }
}

pub fn enableEventChannel(self: *Ctrl, allocator: glib.std.mem.Allocator, capacity: usize) !void {
    if (self.event_channel != null) return;
    self.event_channel = try EventChannel.make(allocator, if (capacity == 0) default_event_capacity else capacity);
}

pub fn events(self: *Ctrl) ?*EventChannel {
    if (self.event_channel) |*channel| return channel;
    return null;
}

pub fn takePendingAction(self: *Ctrl) Action {
    const action = self.pending_action;
    self.pending_action = .none;
    return action;
}

pub fn startRenderThread(self: *Ctrl, display: DisplayApi, config: RenderThreadConfig) !void {
    if (self.render_thread != null) return;
    try self.ensure(display);
    self.render_stop.store(false, .release);
    self.render_thread = try Thread.spawn(config.spawn, renderLoop, .{self});
}

pub fn stopRenderThread(self: *Ctrl) void {
    self.render_stop.store(true, .release);
    if (self.render_thread) |thread| {
        thread.join();
        self.render_thread = null;
    }
}

pub fn renderTick(self: *Ctrl, elapsed_ms: u32) void {
    active_ctrl = self;
    if (!lvgl.isInitialized()) return;
    lvgl.binding.lv_lock();
    defer lvgl.binding.lv_unlock();
    self.renderTickLocked(elapsed_ms);
}

fn renderTickLocked(self: *Ctrl, elapsed_ms: u32) void {
    active_ctrl = self;
    lvgl.Tick.inc(elapsed_ms);
    _ = lvgl.Tick.timerHandler();
}

pub fn setTouchReaderForDefault(reader: TouchReader) void {
    default_ctrl.attachTouchReader(reader);
}

pub fn showDefault(display: DisplayApi, track: Track, mode: Mode, playing: bool, volume: u8) !void {
    try default_ctrl.showState(display, track, mode, playing, volume);
}

pub fn tickDefault(elapsed_ms: u32) void {
    default_ctrl.renderTick(elapsed_ms);
}

pub fn takeDefaultAction() Action {
    return default_ctrl.takePendingAction();
}

fn ensureSubjects(self: *Ctrl) void {
    if (self.track_name_subject == null) {
        self.track_name_subject = StringSubject.init(
            self,
            &self.track_name_buffer,
            &self.track_name_previous_buffer,
            trackTitle(self.track),
        );
    }
    if (self.playing_subject == null) {
        self.playing_subject = IntSubject.init(self, boolInt(self.playing));
    }
    if (self.mic_active_subject == null) {
        self.mic_active_subject = IntSubject.init(self, boolInt(self.mic_active));
    }
    if (self.volume_subject == null) {
        self.volume_subject = IntSubject.init(self, self.volume_value);
        self.volume_subject.?.setMinInt(0);
        self.volume_subject.?.setMaxInt(255);
    }
}

fn deinitSubjects(self: *Ctrl) void {
    self.track_name_subject = null;
    self.playing_subject = null;
    self.mic_active_subject = null;
    self.volume_subject = null;
}

fn createObjects(self: *Ctrl, display: *const lvgl.Display) !void {
    var screen = display.activeScreen();
    screen.removeStyleAll();
    screen.setStyleBgColor(lvgl.Color.fromHex(0x202A4E), selector_main);
    screen.setStyleBgOpa(lvgl.opa.cover, selector_main);

    var card = lvgl.Obj.create(&screen) orelse return error.OutOfMemory;
    card.removeStyleAll();
    card.setSize(284, 208);
    card.center();
    card.removeFlag(lvgl.object.Flags.scrollable);
    card.setStyleBgColor(lvgl.Color.fromHex(0xF8FAFF), selector_main);
    card.setStyleBgOpa(lvgl.opa.cover, selector_main);
    card.setStyleRadius(10, selector_main);
    card.setStyleBorderWidth(0, selector_main);
    card.setStylePadAll(0, selector_main);

    var accent = lvgl.Obj.create(&card) orelse return error.OutOfMemory;
    accent.removeStyleAll();
    accent.setSize(284, 8);
    accent.alignTo(.top_left, 0, 0);
    accent.setStyleBgColor(lvgl.Color.fromHex(0x6973FF), selector_main);
    accent.setStyleBgOpa(lvgl.opa.cover, selector_main);
    accent.setStyleBorderWidth(0, selector_main);

    var art = lvgl.Obj.create(&card) orelse return error.OutOfMemory;
    art.removeStyleAll();
    art.setSize(96, 96);
    art.alignTo(.top_left, 26, 24);
    art.setStyleBgColor(lvgl.Color.fromHex(0x6973FF), selector_main);
    art.setStyleBgOpa(lvgl.opa.cover, selector_main);
    art.setStyleRadius(14, selector_main);
    art.setStyleBorderWidth(0, selector_main);

    var title = lvgl.Label.create(&card) orelse return error.OutOfMemory;
    title.asObj().alignTo(.top_left, 142, 34);
    title.asObj().setStyleTextColor(lvgl.Color.fromHex(0x101830), selector_main);

    var status = lvgl.Label.create(&card) orelse return error.OutOfMemory;
    status.asObj().alignTo(.top_left, 142, 64);
    status.asObj().setStyleTextColor(lvgl.Color.fromHex(0x76809E), selector_main);

    var mic_badge = lvgl.Obj.create(&card) orelse return error.OutOfMemory;
    mic_badge.removeStyleAll();
    mic_badge.setSize(48, 20);
    mic_badge.alignTo(.top_right, -16, 18);
    mic_badge.setStyleBgColor(lvgl.Color.fromHex(0x35C77B), selector_main);
    mic_badge.setStyleBgOpa(lvgl.opa.cover, selector_main);
    mic_badge.setStyleRadius(10, selector_main);
    mic_badge.setStyleBorderWidth(0, selector_main);
    mic_badge.setStylePadAll(0, selector_main);

    var mic_label = lvgl.Label.create(&mic_badge) orelse return error.OutOfMemory;
    mic_label.setTextStatic("MIC");
    mic_label.asObj().center();
    mic_label.asObj().setStyleTextColor(lvgl.Color.white(), selector_main);

    var volume = lvgl.Bar.create(&card) orelse return error.OutOfMemory;
    volume.asObj().setSize(178, 8);
    volume.asObj().alignTo(.top_left, 26, 148);
    volume.asObj().setStyleBgColor(lvgl.Color.fromHex(0xD2D8E8), selector_main);
    volume.asObj().setStyleBgOpa(lvgl.opa.cover, selector_main);
    volume.asObj().setStyleBgColor(lvgl.Color.fromHex(0x101830), selector_indicator);
    volume.asObj().setStyleBgOpa(lvgl.opa.cover, selector_indicator);
    volume.asObj().setStyleRadius(4, selector_main);
    volume.asObj().setStyleRadius(4, selector_indicator);
    volume.setRange(0, 255);

    var volume_text = lvgl.Label.create(&card) orelse return error.OutOfMemory;
    volume_text.asObj().alignTo(.top_left, 216, 140);
    volume_text.asObj().setStyleTextColor(lvgl.Color.fromHex(0x101830), selector_main);

    self.bindButtons();
    _ = try self.createButton(&card, 30, "-", false, &self.volume_down_binding);
    _ = try self.createButton(&card, 82, "<<", false, &self.previous_binding);
    const play_label = try self.createButton(&card, 134, ">", true, &self.play_pause_binding);
    _ = try self.createButton(&card, 186, ">>", false, &self.next_binding);
    _ = try self.createButton(&card, 238, "+", false, &self.volume_up_binding);

    self.ui_objects = .{
        .title = title,
        .status = status,
        .play_label = play_label,
        .mic_badge = mic_badge,
        .volume = volume,
        .volume_text = volume_text,
    };
}

fn bindButtons(self: *Ctrl) void {
    self.volume_down_binding.ctrl = self;
    self.previous_binding.ctrl = self;
    self.play_pause_binding.ctrl = self;
    self.next_binding.ctrl = self;
    self.volume_up_binding.ctrl = self;
}

fn createButton(self: *Ctrl, parent: *const lvgl.Obj, x: i32, text: [:0]const u8, primary: bool, binding: *ButtonBinding) !lvgl.Label {
    _ = self;
    var button = lvgl.Button.create(parent) orelse return error.OutOfMemory;
    var button_obj = button.asObj();
    button_obj.removeStyleAll();
    button_obj.setSize(40, 40);
    button_obj.alignTo(.top_left, x, 166);
    button_obj.setStyleRadius(0, selector_main);
    button_obj.setStyleRadius(0, selector_pressed);
    button_obj.setStyleBorderWidth(0, selector_main);
    button_obj.setStyleBorderWidth(0, selector_pressed);
    button_obj.setStyleOutlineWidth(0, selector_main);
    button_obj.setStyleOutlineWidth(0, selector_pressed);
    button_obj.setStylePadAll(0, selector_main);
    button_obj.setStylePadAll(0, selector_pressed);
    button_obj.setStyleBgOpa(lvgl.opa.cover, selector_main);
    button_obj.setStyleBgColor(
        if (primary) lvgl.Color.fromHex(0x6973FF) else lvgl.Color.fromHex(0xE0E6F6),
        selector_main,
    );
    button_obj.setStyleBgColor(
        if (primary) lvgl.Color.fromHex(0x4F5DFF) else lvgl.Color.fromHex(0xCAD4F0),
        selector_pressed,
    );
    button_obj.setStyleBgOpa(lvgl.opa.cover, selector_pressed);
    button_obj.addEventCallbackRaw(buttonEventCb, lvgl.Event.clicked, binding);

    var label = button.createLabel() orelse return error.OutOfMemory;
    label.setTextStatic(text);
    var label_obj = label.asObj();
    label_obj.center();
    label_obj.setStyleTextColor(
        if (primary) lvgl.Color.white() else lvgl.Color.fromHex(0x101830),
        selector_main,
    );
    return label;
}

fn renderState(self: *Ctrl) void {
    const objects = self.ui_objects orelse return;
    const title_text = if (self.track_name_subject) |*subject|
        subject.getString()
    else
        trackTitle(self.track);
    const playing = if (self.playing_subject) |*subject| subject.getInt() != 0 else self.playing;
    const mic_active = if (self.mic_active_subject) |*subject| subject.getInt() != 0 else self.mic_active;
    const volume = if (self.volume_subject) |*subject| clampVolume(subject.getInt()) else self.volume_value;

    objects.title.setText(title_text);
    objects.status.setText(statusText(playing, mic_active));
    objects.play_label.setText(if (playing) "||" else ">");
    objects.volume.setValue(volume, false);
    objects.volume_text.setText(volumeText(&self.volume_text_buffer, volume));
    objects.mic_badge.setFlag(lvgl.object.Flags.hidden, !mic_active);
}

fn emitAction(self: *Ctrl, action: Action) void {
    if (action == .none) return;
    self.pending_action = action;
    if (self.event_channel) |*channel| {
        _ = channel.sendTimeout(action, 0) catch {};
    }
}

fn renderLoop(self: *Ctrl) void {
    while (!self.render_stop.load(.acquire)) {
        self.renderTick(render_tick_ms);
        Thread.sleep(@intCast(render_tick_ms * esp.grt.time.duration.MilliSecond));
    }
}

fn buttonEventCb(event: ?*lvgl.binding.Event) callconv(.c) void {
    const raw_event = event orelse return;
    var wrapped = lvgl.Event.fromRaw(raw_event);
    if (wrapped.code() != lvgl.Event.clicked) return;
    const user_data = wrapped.userData() orelse return;
    const binding: *ButtonBinding = @ptrCast(@alignCast(user_data));
    const ctrl = binding.ctrl orelse return;
    ctrl.emitAction(binding.action);
}

fn touchReadCb(_: ?*lvgl.binding.Indev, data: ?*lvgl.binding.IndevData) callconv(.c) void {
    const out = data orelse return;
    const ctrl = active_ctrl orelse return;
    if (ctrl.touch_reader) |reader| {
        if (reader()) |point| {
            ctrl.last_touch = point;
            out.point.x = @intCast(point.x);
            out.point.y = @intCast(point.y);
            out.state = @as(lvgl.binding.IndevState, @intCast(@intFromEnum(lvgl.Indev.State.pressed)));
            return;
        }
    }

    out.point.x = @intCast(ctrl.last_touch.x);
    out.point.y = @intCast(ctrl.last_touch.y);
    out.state = @as(lvgl.binding.IndevState, @intCast(@intFromEnum(lvgl.Indev.State.released)));
}

fn flushCb(
    display: ?*lvgl.binding.Display,
    area: ?*const lvgl.binding.Area,
    px_map: ?*u8,
) callconv(.c) void {
    defer if (display) |handle| lvgl.binding.lv_display_flush_ready(handle);
    const ctrl = active_ctrl orelse return;
    if (!ctrl.display_ready) return;

    const draw_area = area orelse return;
    const pixels = px_map orelse return;
    if (draw_area.x1 < 0 or draw_area.y1 < 0) return;
    const x: u16 = @intCast(draw_area.x1);
    const y: u16 = @intCast(draw_area.y1);
    const w: u16 = @intCast(draw_area.x2 - draw_area.x1 + 1);
    const h: u16 = @intCast(draw_area.y2 - draw_area.y1 + 1);
    const count = @as(usize, w) * @as(usize, h);
    const byte_count = count * rgb888_bytes_per_pixel;
    if (count > ctrl.flush_buffer.len or byte_count > ctrl.draw_buffer.len) return;

    const bytes: [*]const u8 = @ptrCast(pixels);
    for (0..count) |index| {
        const base = index * rgb888_bytes_per_pixel;
        ctrl.flush_buffer[index] = DisplayApi.rgb(
            bytes[base + 2],
            bytes[base + 1],
            bytes[base + 0],
        );
    }
    ctrl.display.drawBitmap(x, y, w, h, ctrl.flush_buffer[0..count]) catch {};
}

fn trackTitle(track: Track) [:0]const u8 {
    return switch (track) {
        .twinkle => "Twinkle",
        .happy_birthday => "Happy Birthday",
        .doll_bear => "Doll Bear",
    };
}

fn statusText(playing: bool, mic_active: bool) [:0]const u8 {
    if (mic_active and playing) return "Playing + Mic";
    if (mic_active) return "Paused + Mic";
    return if (playing) "Playing" else "Paused";
}

fn volumeText(buffer: *[volume_text_buffer_len:0]u8, volume: i32) [:0]const u8 {
    @memset(buffer[0..], 0);
    buffer[0] = 'V';
    buffer[1] = 'o';
    buffer[2] = 'l';
    buffer[3] = ' ';

    const value: u8 = @intCast(clampVolume(volume));
    var digits: [3]u8 = undefined;
    var n: usize = 0;
    var remaining = value;
    while (true) {
        digits[n] = '0' + (remaining % 10);
        n += 1;
        remaining /= 10;
        if (remaining == 0) break;
    }

    var i: usize = 0;
    while (i < n) : (i += 1) {
        buffer[4 + i] = digits[n - 1 - i];
    }
    return buffer[0.. :0];
}

fn boolInt(value: bool) i32 {
    return if (value) 1 else 0;
}

fn clampVolume(value: i32) i32 {
    if (value <= 0) return 0;
    if (value >= 255) return 255;
    return value;
}

fn clampI32(value: i32, min_value: i32, max_value: i32) i32 {
    if (value < min_value) return min_value;
    if (value > max_value) return max_value;
    return value;
}

fn copyZ(dest: *[title_buffer_len:0]u8, source: [:0]const u8) void {
    @memset(dest[0..], 0);
    const n = @min(source.len, title_buffer_len - 1);
    @memcpy(dest[0..n], source[0..n]);
}

pub fn setTouchReader(reader: TouchReader) void {
    setTouchReaderForDefault(reader);
}

pub fn show(display: DisplayApi, track: Track, mode: Mode, playing: bool, volume: u8) !void {
    try showDefault(display, track, mode, playing, volume);
}

pub fn tick(elapsed_ms: u32) void {
    tickDefault(elapsed_ms);
}

pub fn takeAction() Action {
    return takeDefaultAction();
}
