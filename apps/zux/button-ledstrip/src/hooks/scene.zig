const embed = @import("embed");
const glib = @import("glib");
const ledstrip = embed.ledstrip;

const led_brightness: u8 = 255;
const power_hold_interval: glib.time.duration.Duration = 3 * glib.time.duration.Second;
const marquee_hold_interval: glib.time.duration.Duration = 5 * glib.time.duration.Second;
const animation_interval: glib.time.duration.Duration = 10 * glib.time.duration.MilliSecond;

const black: u32 = 0x000000;
const red: u32 = 0xff0000;
const blue: u32 = 0x0000ff;
const green: u32 = 0x00ff00;
const yellow: u32 = 0xffff00;
const white: u32 = 0xffffff;

pub const Scene = struct {
    last_tick_ns: ?i64 = null,
    last_hold_ns: ?glib.time.duration.Duration = null,
    hold_3s_applied: bool = false,

    pub fn reduce(
        self: *@This(),
        stores: anytype,
        message: anytype,
        emit: anytype,
    ) !usize {
        _ = emit;
        var scene = stores.scene.get();
        const before = scene;
        const timestamp_ns: i64 = @intCast(message.timestamp);
        switch (message.body) {
            .button_gesture => |button| self.applyButton(&scene, button),
            .tick => self.applyTick(&scene, timestamp_ns),
            else => return 0,
        }

        if (sceneEqual(before, scene)) return 0;
        stores.scene.set(scene);
        return 1;
    }

    pub fn render(self: *@This(), app: anytype) !void {
        _ = self;
        const AppType = @TypeOf(app.*);
        const StripType = AppType.LedStrip(.strip);
        const state = app.store().stores.scene.get();

        try app.set_led_strip_pixels(
            .strip,
            StripType.FrameType.solid(colorFromU32(state.visible_color)),
            led_brightness,
        );
    }

    fn applyTick(self: *@This(), scene: anytype, timestamp_ns: i64) void {
        if (timestamp_ns < animation_interval) return;
        if (self.last_tick_ns) |last_tick_ns| {
            if (timestamp_ns - last_tick_ns < animation_interval) return;
        }
        self.last_tick_ns = timestamp_ns;

        switch (scene.mode) {
            .solid => stepSolid(scene),
            .marquee => stepMarquee(scene),
            .off => {},
        }
    }

    fn applyButton(self: *@This(), scene: anytype, button: anytype) void {
        switch (button.gesture) {
            .click => self.applyClick(scene),
            .long_press => |held| self.applyLongPress(scene, held),
        }
    }

    fn applyClick(self: *@This(), scene: anytype) void {
        self.last_tick_ns = null;
        self.resetHoldTracking();
        if (scene.mode == .off or scene.mode == .marquee) return;
        setSolidTarget(scene, nextColorName(scene.target_color_name), scene.visible_color != colorForName(nextColorName(scene.target_color_name)));
    }

    fn applyLongPress(self: *@This(), scene: anytype, held: glib.time.duration.Duration) void {
        self.last_tick_ns = null;
        self.updateHoldTracking(held);
        if (held >= marquee_hold_interval) {
            const visible_color = if (scene.target_color_name == .white) scene.visible_color else black;
            setMarquee(scene, .red, visible_color, true);
            self.hold_3s_applied = true;
            return;
        }

        if (held < power_hold_interval) return;
        if (self.hold_3s_applied) return;
        self.hold_3s_applied = true;
        if (scene.mode == .off) {
            setSolidTarget(scene, .white, false);
            scene.visible_color = white;
        } else {
            setOff(scene);
        }
    }

    fn updateHoldTracking(self: *@This(), held: glib.time.duration.Duration) void {
        if (self.last_hold_ns) |last_hold_ns| {
            if (held <= last_hold_ns) {
                self.hold_3s_applied = false;
            }
        } else {
            self.hold_3s_applied = false;
        }
        self.last_hold_ns = held;
    }

    fn resetHoldTracking(self: *@This()) void {
        self.last_hold_ns = null;
        self.hold_3s_applied = false;
    }
};

fn stepSolid(scene: anytype) void {
    if (!scene.transitioning) return;
    scene.visible_color = stepColor(scene.visible_color, scene.target_color);
    scene.transitioning = scene.visible_color != scene.target_color;
}

fn stepMarquee(scene: anytype) void {
    if (scene.visible_color == scene.target_color) {
        const next_stage = nextMarqueeStage(scene.marquee_stage);
        setMarquee(scene, next_stage, scene.visible_color, true);
        return;
    }
    scene.visible_color = stepColor(scene.visible_color, scene.target_color);
    if (scene.visible_color == scene.target_color) {
        const next_stage = nextMarqueeStage(scene.marquee_stage);
        setMarquee(scene, next_stage, scene.visible_color, true);
    } else {
        scene.transitioning = true;
    }
}

fn setOff(scene: anytype) void {
    scene.mode = .off;
    scene.target_color_name = .none;
    scene.target_color = black;
    scene.visible_color = black;
    scene.transitioning = false;
    scene.marquee_stage = .none;
}

fn setSolidTarget(scene: anytype, target_name: anytype, transitioning: bool) void {
    const typed_target_name: @TypeOf(scene.target_color_name) = target_name;
    scene.mode = .solid;
    scene.target_color_name = typed_target_name;
    scene.target_color = colorForName(typed_target_name);
    scene.transitioning = transitioning;
    scene.marquee_stage = .none;
}

fn setMarquee(scene: anytype, stage: anytype, visible_color: u32, transitioning: bool) void {
    const typed_stage: @TypeOf(scene.marquee_stage) = stage;
    scene.mode = .marquee;
    scene.target_color_name = switch (typed_stage) {
        .red => .red,
        .green => .green,
        .blue => .blue,
        .none => .none,
    };
    scene.target_color = colorForName(scene.target_color_name);
    scene.visible_color = visible_color;
    scene.transitioning = transitioning;
    scene.marquee_stage = typed_stage;
}

fn nextColorName(color_name: anytype) @TypeOf(color_name) {
    return switch (color_name) {
        .red => .blue,
        .blue => .green,
        .green => .yellow,
        .yellow => .red,
        .white => .red,
        .none => .none,
    };
}

fn nextMarqueeStage(stage: anytype) @TypeOf(stage) {
    return switch (stage) {
        .red => .green,
        .green => .blue,
        .blue => .red,
        .none => .red,
    };
}

fn colorForName(color_name: anytype) u32 {
    return switch (color_name) {
        .none => black,
        .red => red,
        .blue => blue,
        .green => green,
        .yellow => yellow,
        .white => white,
    };
}

fn stepColor(current: u32, target: u32) u32 {
    const current_r = channel(current, 16);
    const current_g = channel(current, 8);
    const current_b = channel(current, 0);
    const target_r = channel(target, 16);
    const target_g = channel(target, 8);
    const target_b = channel(target, 0);
    return packColor(
        stepChannel(current_r, target_r),
        stepChannel(current_g, target_g),
        stepChannel(current_b, target_b),
    );
}

fn stepChannel(current: u8, target: u8) u8 {
    if (current == target) return current;
    const diff = if (current < target) target - current else current - target;
    if (diff <= 1) return target;
    const step: u8 = @intCast((@as(u16, diff) + 15) / 16);
    return if (current < target) current + step else current - step;
}

fn channel(color: u32, shift: u5) u8 {
    return @intCast((color >> shift) & 0xff);
}

fn packColor(r: u8, g: u8, b: u8) u32 {
    return (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b);
}

fn colorFromU32(color: u32) ledstrip.Color {
    return ledstrip.Color.rgb(channel(color, 16), channel(color, 8), channel(color, 0));
}

fn sceneEqual(a: anytype, b: @TypeOf(a)) bool {
    return a.mode == b.mode and
        a.target_color_name == b.target_color_name and
        a.target_color == b.target_color and
        a.visible_color == b.visible_color and
        a.transitioning == b.transitioning and
        a.marquee_stage == b.marquee_stage;
}
