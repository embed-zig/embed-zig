const embed = @import("embed");
const glib = @import("glib");
const ledstrip = embed.ledstrip;
const zux = embed.zux;

const led_brightness: u8 = 255;
const Mode = struct {
    const off: u8 = 0;
    const red: u8 = 1;
    const green: u8 = 2;
    const blue: u8 = 3;
    const rainbow: u8 = 4;
};
const rainbow_step_interval: glib.time.duration.Duration = 120 * glib.time.duration.MilliSecond;

pub const rainbow_palette = [_]ledstrip.Color{
    ledstrip.Color.red,
    ledstrip.Color.rgb(255, 127, 0),
    ledstrip.Color.rgb(255, 255, 0),
    ledstrip.Color.green,
    ledstrip.Color.rgb(0, 255, 255),
    ledstrip.Color.blue,
    ledstrip.Color.rgb(139, 0, 255),
};

pub fn sceneReducer(comptime Stores: type, comptime MessageType: type, comptime EmitterType: type) zux.ReducerFnType(Stores, MessageType, EmitterType) {
    return struct {
        fn reduce(stores: *Stores, message: MessageType, emit: EmitterType) !usize {
            _ = emit;
            var scene = stores.scene.get();
            const timestamp_ns: i64 = @intCast(message.timestamp);
            const changed = switch (message.body) {
                .tick => |tick| applyTick(&scene, tick.seq, timestamp_ns),
                else => return 0,
            };

            if (!changed) return 0;
            stores.scene.set(scene);
            return 1;
        }
    }.reduce;
}

pub fn renderScene(comptime AppType: type, comptime path: []const u8) *const fn (*AppType) anyerror!void {
    _ = path;

    return struct {
        fn render(app: *AppType) !void {
            const StripType = AppType.LedStrip(.strip);
            const state = app.store().stores.scene.get();

            switch (state.mode) {
                Mode.off => try app.set_led_strip_pixels(
                    .strip,
                    StripType.FrameType.solid(ledstrip.Color.black),
                    led_brightness,
                ),
                Mode.red => try app.set_led_strip_pixels(
                    .strip,
                    StripType.FrameType.solid(ledstrip.Color.red),
                    led_brightness,
                ),
                Mode.green => try app.set_led_strip_pixels(
                    .strip,
                    StripType.FrameType.solid(ledstrip.Color.green),
                    led_brightness,
                ),
                Mode.blue => try app.set_led_strip_pixels(
                    .strip,
                    StripType.FrameType.solid(ledstrip.Color.blue),
                    led_brightness,
                ),
                Mode.rainbow => try app.set_led_strip_pixels(
                    .strip,
                    StripType.FrameType.solid(rainbowColor(state)),
                    led_brightness,
                ),
                else => try app.set_led_strip_pixels(
                    .strip,
                    StripType.FrameType.solid(ledstrip.Color.black),
                    led_brightness,
                ),
            }
        }
    }.render;
}

fn applyTick(
    scene: anytype,
    seq: u64,
    timestamp_ns: i64,
) bool {
    switch (seq) {
        1 => return setMode(scene, Mode.red, timestamp_ns),
        2 => return setMode(scene, Mode.green, timestamp_ns),
        3 => return setMode(scene, Mode.blue, timestamp_ns),
        4 => return false,
        30 => return setMode(scene, Mode.off, timestamp_ns),
        50 => return setMode(scene, Mode.rainbow, timestamp_ns),
        else => {},
    }

    if (scene.mode != Mode.rainbow) {
        if (scene.next_rainbow_step_ns == 0) return false;
        scene.next_rainbow_step_ns = 0;
        return true;
    }

    if (scene.next_rainbow_step_ns == 0) {
        scene.next_rainbow_step_ns = timestamp_ns + rainbow_step_interval;
        return true;
    }
    if (timestamp_ns < scene.next_rainbow_step_ns) return false;

    const elapsed_ns = timestamp_ns - scene.next_rainbow_step_ns;
    const step_count: usize = @intCast(@divFloor(elapsed_ns, rainbow_step_interval) + 1);
    scene.rainbow_stage = nextRainbowStage(scene.rainbow_stage, step_count);
    scene.next_rainbow_step_ns += @as(i64, @intCast(step_count)) * rainbow_step_interval;
    return true;
}

fn setMode(
    scene: anytype,
    mode: u8,
    timestamp_ns: i64,
) bool {
    const next_step_ns = switch (mode) {
        Mode.rainbow => timestamp_ns + rainbow_step_interval,
        else => 0,
    };
    if (scene.mode == mode and scene.rainbow_stage == 0 and scene.next_rainbow_step_ns == next_step_ns) return false;
    scene.mode = mode;
    scene.rainbow_stage = 0;
    scene.next_rainbow_step_ns = next_step_ns;
    return true;
}

fn nextRainbowStage(current: u8, step_count: usize) u8 {
    return @intCast((@as(usize, current) + step_count) % rainbow_palette.len);
}

fn rainbowColor(state: anytype) ledstrip.Color {
    return rainbow_palette[state.rainbow_stage % rainbow_palette.len];
}
