const lvgl = @import("lvgl");

const consts = @import("../../consts.zig");

const selector_main = lvgl.binding.LV_PART_MAIN;

pub fn make(comptime State: type) type {
    return struct {
        const Screen = @This();

        root: lvgl.Obj,
        width: i32,
        height: i32,
        bars: [consts.color.split.len]lvgl.Obj,
        last_scene: ?State = null,

        pub fn init(display: lvgl.Display) !Screen {
            var screen = display.activeScreen();
            screen.clean();
            screen.removeStyleAll();
            screen.removeFlag(lvgl.object.Flags.scrollable);
            screen.setStyleBgOpa(lvgl.opa.cover, selector_main);

            var bars: [consts.color.split.len]lvgl.Obj = undefined;
            inline for (0..consts.color.split.len) |i| {
                bars[i] = lvgl.Obj.create(&screen) orelse return error.OutOfMemory;
                bars[i].removeStyleAll();
                bars[i].removeFlag(lvgl.object.Flags.scrollable);
                bars[i].setStyleBgOpa(lvgl.opa.cover, selector_main);
                bars[i].setStyleBorderWidth(0, selector_main);
                bars[i].setStyleOutlineWidth(0, selector_main);
                bars[i].setStylePadAll(0, selector_main);
                bars[i].setStyleRadius(0, selector_main);
            }

            return .{
                .root = screen,
                .width = display.width(),
                .height = display.height(),
                .bars = bars,
            };
        }

        pub fn setState(self: *Screen, state: State) void {
            if (self.last_scene) |last_scene| {
                if (last_scene.current == state.current) return;
            }
            self.last_scene = state;

            if (state.current == .split_7_colors) {
                self.setSplit(self.width, self.height);
            } else {
                self.setSolid(self.width, self.height, consts.sceneColor(state.current));
            }
        }

        fn setSplit(self: *Screen, width: i32, height: i32) void {
            const bar_count: i32 = @intCast(self.bars.len);
            const base_width = @divTrunc(width, bar_count);
            var x: i32 = 0;
            inline for (0..consts.color.split.len) |i| {
                const remaining_width = width - x;
                const next_width = if (i == consts.color.split.len - 1) remaining_width else base_width;
                self.bars[i].setPos(x, 0);
                self.bars[i].setSize(next_width, height);
                self.bars[i].setStyleBgColor(lvgl.Color.fromHex(consts.color.split[i]), selector_main);
                x += next_width;
            }
        }

        fn setSolid(self: *Screen, width: i32, height: i32, rgb: u32) void {
            self.bars[0].setPos(0, 0);
            self.bars[0].setSize(width, height);
            self.bars[0].setStyleBgColor(lvgl.Color.fromHex(rgb), selector_main);
            for (self.bars[1..]) |bar| {
                bar.setSize(0, 0);
            }
        }
    };
}
