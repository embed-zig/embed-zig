const glib = @import("glib");
const lvgl = @import("lvgl");

const selector_main = lvgl.binding.LV_PART_MAIN;

pub fn make(comptime State: type) type {
    return struct {
        const Screen = @This();

        raw_label: lvgl.Label,
        gesture_label: lvgl.Label,
        count_label: lvgl.Label,
        raw_text: [64:0]u8 = [_:0]u8{0} ** 64,
        gesture_text: [64:0]u8 = [_:0]u8{0} ** 64,
        count_text: [72:0]u8 = [_:0]u8{0} ** 72,

        pub fn init(display: lvgl.Display) !Screen {
            var screen = display.activeScreen();
            screen.clean();
            screen.removeStyleAll();
            screen.removeFlag(lvgl.object.Flags.scrollable);
            screen.setStyleBgColor(lvgl.Color.fromHex(0x101418), selector_main);
            screen.setStyleBgOpa(lvgl.opa.cover, selector_main);

            var panel = lvgl.Obj.create(&screen) orelse return error.OutOfMemory;
            panel.removeStyleAll();
            panel.setSize(display.width() - 24, display.height() - 24);
            panel.center();
            panel.removeFlag(lvgl.object.Flags.scrollable);
            panel.setStyleBgColor(lvgl.Color.fromHex(0x20262d), selector_main);
            panel.setStyleBgOpa(lvgl.opa.cover, selector_main);
            panel.setStyleRadius(8, selector_main);
            panel.setStyleBorderWidth(0, selector_main);
            panel.setStylePadAll(0, selector_main);

            var title = try createLabel(&panel, 20, 18, 0xe8edf2);
            title.setTextStatic("ADC Group Debug");

            return .{
                .raw_label = try createLabel(&panel, 20, 64, 0x66d9ef),
                .gesture_label = try createLabel(&panel, 20, 102, 0xffcc66),
                .count_label = try createLabel(&panel, 20, 140, 0xa8b3bd),
            };
        }

        pub fn setState(self: *Screen, state: State) void {
            self.setLabelText(
                &self.raw_text,
                self.raw_label,
                "raw id={d} pressed={}",
                .{ state.raw_id, state.raw_pressed },
            );
            self.setLabelText(
                &self.gesture_text,
                self.gesture_label,
                "click id={d} count={d}",
                .{ state.gesture_id, state.click_count },
            );
            self.setLabelText(
                &self.count_text,
                self.count_label,
                "raw_events={d} gesture_events={d}",
                .{ state.raw_events, state.gesture_events },
            );
        }

        fn createLabel(parent: *const lvgl.Obj, x: i32, y: i32, color: u32) !lvgl.Label {
            var label = lvgl.Label.create(parent) orelse return error.OutOfMemory;
            var obj = label.asObj();
            obj.alignTo(.top_left, x, y);
            obj.setStyleTextColor(lvgl.Color.fromHex(color), selector_main);
            return label;
        }

        fn setLabelText(self: *Screen, buffer: anytype, label: lvgl.Label, comptime fmt: []const u8, args: anytype) void {
            _ = self;
            const text = glib.std.fmt.bufPrintZ(buffer, fmt, args) catch buffer[0..0 :0];
            label.setText(text);
        }
    };
}
