const embed = @import("embed");
const lvgl = @import("lvgl");

const DisplayApi = embed.drivers.Display;
const Rgb = DisplayApi.Rgb;

const width_px: u16 = 320;
const height_px: u16 = 240;
const draw_rows: u16 = 20;
const max_draw_pixels = @as(usize, width_px) * @as(usize, draw_rows);
const rgb888_bytes_per_pixel = 3;
const max_draw_bytes = max_draw_pixels * rgb888_bytes_per_pixel;
const selector_main = lvgl.binding.LV_PART_MAIN;
const selector_indicator = lvgl.binding.LV_PART_INDICATOR;
const selector_pressed = lvgl.binding.LV_PART_MAIN | lvgl.binding.LV_STATE_PRESSED;

pub const Track = enum(c_int) {
    twinkle = 0,
    happy_birthday = 1,
    doll_bear = 2,
};

pub const Action = enum {
    none,
    play_pause,
    next,
    previous,
    volume_up,
    volume_down,
};

pub const TouchPoint = struct {
    x: u16,
    y: u16,
};

pub const TouchReader = *const fn () ?TouchPoint;

const UiObjects = struct {
    title: lvgl.Label,
    status: lvgl.Label,
    play_label: lvgl.Label,
    volume: lvgl.Bar,
};

var target_display: DisplayApi = undefined;
var target_display_ready = false;
var lv_display: ?lvgl.Display = null;
var lv_indev: ?lvgl.Indev = null;
var ui_ready = false;
var ui_objects: ?UiObjects = null;
var draw_buffer: [max_draw_bytes]u8 align(64) = undefined;
var flush_buffer: [max_draw_pixels]Rgb = undefined;
var touch_reader: ?TouchReader = null;
var last_touch: TouchPoint = .{ .x = 0, .y = 0 };
var pending_action: Action = .none;
var volume_down_action: Action = .volume_down;
var previous_action: Action = .previous;
var play_pause_action: Action = .play_pause;
var next_action: Action = .next;
var volume_up_action: Action = .volume_up;

pub fn setTouchReader(reader: TouchReader) void {
    touch_reader = reader;
}

pub fn show(display: DisplayApi, track: Track, playing: bool, volume: u8) !void {
    try ensure(display);
    const objects = ui_objects orelse return error.DisplayError;

    objects.title.setTextStatic(trackTitle(track));
    objects.status.setTextStatic(if (playing) "Playing" else "Paused");
    objects.play_label.setTextStatic(if (playing) "||" else ">");
    objects.volume.setValue(volume, false);

    tick(1);
}

pub fn takeAction() Action {
    const action = pending_action;
    pending_action = .none;
    return action;
}

pub fn tick(elapsed_ms: u32) void {
    if (!lvgl.isInitialized()) return;
    lvgl.Tick.inc(elapsed_ms);
    _ = lvgl.Tick.timerHandler();
}

fn ensure(display: DisplayApi) !void {
    target_display = display;
    target_display_ready = true;

    if (!lvgl.isInitialized()) {
        lvgl.init();
    }
    if (ui_ready) return;

    var created_display = lvgl.Display.create(width_px, height_px) orelse return error.OutOfMemory;
    created_display.setColorFormat(lvgl.binding.LV_COLOR_FORMAT_RGB888);
    created_display.setBuffers(
        @ptrCast(draw_buffer[0..].ptr),
        null,
        @intCast(draw_buffer.len),
        lvgl.binding.LV_DISPLAY_RENDER_MODE_PARTIAL,
    );
    created_display.setFlushCb(flushCb);
    created_display.setDefault();
    lv_display = created_display;

    var created_indev = lvgl.Indev.create() orelse return error.OutOfMemory;
    created_indev.setDisplay(&created_display);
    created_indev.setType(.pointer);
    created_indev.setReadCb(touchReadCb);
    lv_indev = created_indev;

    try createObjects(&created_display);
    ui_ready = true;
}

fn createObjects(display: *const lvgl.Display) !void {
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

    var volume = lvgl.Bar.create(&card) orelse return error.OutOfMemory;
    volume.asObj().setSize(232, 8);
    volume.asObj().alignTo(.top_left, 26, 148);
    volume.asObj().setStyleBgColor(lvgl.Color.fromHex(0xD2D8E8), selector_main);
    volume.asObj().setStyleBgOpa(lvgl.opa.cover, selector_main);
    volume.asObj().setStyleBgColor(lvgl.Color.fromHex(0x101830), selector_indicator);
    volume.asObj().setStyleBgOpa(lvgl.opa.cover, selector_indicator);
    volume.asObj().setStyleRadius(4, selector_main);
    volume.asObj().setStyleRadius(4, selector_indicator);
    volume.setRange(0, 255);

    _ = try createButton(&card, 42, "-", false, &volume_down_action);
    _ = try createButton(&card, 92, "<<", false, &previous_action);
    const play_label = try createButton(&card, 142, ">", true, &play_pause_action);
    _ = try createButton(&card, 192, ">>", false, &next_action);
    _ = try createButton(&card, 242, "+", false, &volume_up_action);

    ui_objects = .{
        .title = title,
        .status = status,
        .play_label = play_label,
        .volume = volume,
    };
}

fn createButton(parent: *const lvgl.Obj, x: i32, text: [:0]const u8, primary: bool, action: *Action) !lvgl.Label {
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
    button_obj.addEventCallbackRaw(buttonEventCb, lvgl.Event.clicked, action);

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

fn buttonEventCb(event: ?*lvgl.binding.Event) callconv(.c) void {
    const raw_event = event orelse return;
    var wrapped = lvgl.Event.fromRaw(raw_event);
    if (wrapped.code() != lvgl.Event.clicked) return;
    const user_data = wrapped.userData() orelse return;
    const action: *Action = @ptrCast(@alignCast(user_data));
    pending_action = action.*;
}

fn touchReadCb(_: ?*lvgl.binding.Indev, data: ?*lvgl.binding.IndevData) callconv(.c) void {
    const out = data orelse return;
    if (touch_reader) |reader| {
        if (reader()) |point| {
            last_touch = point;
            out.point.x = @intCast(point.x);
            out.point.y = @intCast(point.y);
            out.state = @as(lvgl.binding.IndevState, @intCast(@intFromEnum(lvgl.Indev.State.pressed)));
            return;
        }
    }

    out.point.x = @intCast(last_touch.x);
    out.point.y = @intCast(last_touch.y);
    out.state = @as(lvgl.binding.IndevState, @intCast(@intFromEnum(lvgl.Indev.State.released)));
}

fn trackTitle(track: Track) [:0]const u8 {
    return switch (track) {
        .twinkle => "Twinkle",
        .happy_birthday => "Happy Birthday",
        .doll_bear => "Doll Bear",
    };
}

fn flushCb(
    display: ?*lvgl.binding.Display,
    area: ?*const lvgl.binding.Area,
    px_map: ?*u8,
) callconv(.c) void {
    defer if (display) |handle| lvgl.binding.lv_display_flush_ready(handle);
    if (!target_display_ready) return;

    const draw_area = area orelse return;
    const pixels = px_map orelse return;
    if (draw_area.x1 < 0 or draw_area.y1 < 0) return;
    const x: u16 = @intCast(draw_area.x1);
    const y: u16 = @intCast(draw_area.y1);
    const w: u16 = @intCast(draw_area.x2 - draw_area.x1 + 1);
    const h: u16 = @intCast(draw_area.y2 - draw_area.y1 + 1);
    const count = @as(usize, w) * @as(usize, h);
    const byte_count = count * rgb888_bytes_per_pixel;
    if (count > flush_buffer.len or byte_count > draw_buffer.len) return;

    const bytes: [*]const u8 = @ptrCast(pixels);
    for (0..count) |index| {
        const base = index * rgb888_bytes_per_pixel;
        flush_buffer[index] = DisplayApi.rgb(
            bytes[base + 2],
            bytes[base + 1],
            bytes[base + 0],
        );
    }
    target_display.drawBitmap(x, y, w, h, flush_buffer[0..count]) catch {};
}
