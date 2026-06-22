const lvgl = @import("lvgl");

const Theme = @import("Theme.zig");

pub fn make(comptime State: type) type {
    return struct {
        const Screen = @This();

        title_label: lvgl.Label,
        role_label: lvgl.Label,
        link_label: lvgl.Label,
        mtu_label: lvgl.Label,
        tx_label: lvgl.Label,
        rx_label: lvgl.Label,
        error_label: lvgl.Label,
        title_text: [32:0]u8 = [_:0]u8{0} ** 32,
        role_text: [48:0]u8 = [_:0]u8{0} ** 48,
        link_text: [80:0]u8 = [_:0]u8{0} ** 80,
        mtu_text: [64:0]u8 = [_:0]u8{0} ** 64,
        tx_text: [80:0]u8 = [_:0]u8{0} ** 80,
        rx_text: [96:0]u8 = [_:0]u8{0} ** 96,
        error_text: [48:0]u8 = [_:0]u8{0} ** 48,

        pub fn init(display: lvgl.Display) !Screen {
            var screen = display.activeScreen();
            screen.clean();
            screen.removeStyleAll();
            screen.setStyleBgColor(Theme.bg, Theme.selector_main);
            screen.setStyleBgOpa(lvgl.opa.cover, Theme.selector_main);

            var panel = lvgl.Obj.create(&screen) orelse return error.OutOfMemory;
            panel.removeStyleAll();
            panel.setSize(300, 210);
            panel.center();
            panel.removeFlag(lvgl.object.Flags.scrollable);
            panel.setStyleBgColor(Theme.panel, Theme.selector_main);
            panel.setStyleBgOpa(lvgl.opa.cover, Theme.selector_main);
            panel.setStyleRadius(12, Theme.selector_main);
            panel.setStyleBorderWidth(0, Theme.selector_main);
            panel.setStylePadAll(0, Theme.selector_main);

            var accent = lvgl.Obj.create(&panel) orelse return error.OutOfMemory;
            accent.removeStyleAll();
            accent.setSize(300, 8);
            accent.alignTo(.top_left, 0, 0);
            accent.setStyleBgColor(Theme.accent, Theme.selector_main);
            accent.setStyleBgOpa(lvgl.opa.cover, Theme.selector_main);
            accent.setStyleBorderWidth(0, Theme.selector_main);

            return .{
                .title_label = try createLabel(&panel, 18, 22, Theme.text),
                .role_label = try createLabel(&panel, 18, 54, Theme.muted),
                .link_label = try createLabel(&panel, 18, 80, Theme.muted),
                .mtu_label = try createLabel(&panel, 18, 106, Theme.muted),
                .tx_label = try createLabel(&panel, 18, 136, Theme.tx),
                .rx_label = try createLabel(&panel, 18, 162, Theme.rx),
                .error_label = try createLabel(&panel, 218, 54, Theme.quiet),
            };
        }

        pub fn setState(self: *Screen, state: State) void {
            self.setLabel(&self.title_text, self.title_label, state.title_buf, state.title_len);
            self.setLabel(&self.role_text, self.role_label, state.role_buf, state.role_len);
            self.setLabel(&self.link_text, self.link_label, state.link_buf, state.link_len);
            self.setLabel(&self.mtu_text, self.mtu_label, state.mtu_buf, state.mtu_len);
            self.setLabel(&self.tx_text, self.tx_label, state.tx_buf, state.tx_len);
            self.setLabel(&self.rx_text, self.rx_label, state.rx_buf, state.rx_len);
            self.setLabel(&self.error_text, self.error_label, state.error_buf, state.error_len);
            self.error_label.asObj().setStyleTextColor(
                if (state.phase == .failed) Theme.danger else Theme.quiet,
                Theme.selector_main,
            );
        }

        fn createLabel(parent: *const lvgl.Obj, x: i32, y: i32, color: lvgl.Color) !lvgl.Label {
            var label = lvgl.Label.create(parent) orelse return error.OutOfMemory;
            var obj = label.asObj();
            obj.alignTo(.top_left, x, y);
            obj.setStyleTextColor(color, Theme.selector_main);
            return label;
        }

        fn setLabel(self: *Screen, buffer: anytype, label: lvgl.Label, bytes: anytype, len: u8) void {
            _ = self;
            const capped_len = @min(@as(usize, len), @min(bytes.len, buffer.len - 1));
            @memcpy(buffer[0..capped_len], bytes[0..capped_len]);
            buffer[capped_len] = 0;
            label.setText(buffer[0..capped_len :0]);
        }
    };
}
