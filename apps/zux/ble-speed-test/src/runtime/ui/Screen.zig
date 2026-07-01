const glib = @import("glib");
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
        overlay_label: lvgl.Label,
        title_text: [32:0]u8 = [_:0]u8{0} ** 32,
        role_text: [48:0]u8 = [_:0]u8{0} ** 48,
        link_text: [80:0]u8 = [_:0]u8{0} ** 80,
        mtu_text: [64:0]u8 = [_:0]u8{0} ** 64,
        tx_text: [80:0]u8 = [_:0]u8{0} ** 80,
        rx_text: [96:0]u8 = [_:0]u8{0} ** 96,
        error_text: [48:0]u8 = [_:0]u8{0} ** 48,
        overlay_text: [128:0]u8 = [_:0]u8{0} ** 128,

        pub const RuntimeOverlay = struct {
            cpu_valid: bool = false,
            cpu_core_count: u8 = 0,
            idle_percent: [2]u8 = [_]u8{0} ** 2,
            memory_valid: bool = false,
            diram_free: usize = 0,
            psram_free: usize = 0,
        };

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

            var overlay = lvgl.Obj.create(&screen) orelse return error.OutOfMemory;
            overlay.removeStyleAll();
            overlay.setSize(160, 78);
            overlay.alignTo(.bottom_right, -4, -4);
            overlay.removeFlag(lvgl.object.Flags.scrollable);
            overlay.setStyleBgColor(Theme.overlay_bg, Theme.selector_main);
            overlay.setStyleBgOpa(lvgl.opa.pct80, Theme.selector_main);
            overlay.setStyleRadius(8, Theme.selector_main);
            overlay.setStyleBorderWidth(0, Theme.selector_main);
            overlay.setStylePadAll(0, Theme.selector_main);

            var overlay_label = lvgl.Label.create(&overlay) orelse return error.OutOfMemory;
            overlay_label.asObj().alignTo(.top_left, 6, 5);
            overlay_label.asObj().setSize(150, 68);
            overlay_label.asObj().setStyleTextColor(Theme.overlay_text, Theme.selector_main);
            overlay_label.setLongMode(lvgl.Label.long_mode_clip);

            return .{
                .title_label = try createLabel(&panel, 18, 22, Theme.text),
                .role_label = try createLabel(&panel, 18, 54, Theme.muted),
                .link_label = try createLabel(&panel, 18, 80, Theme.muted),
                .mtu_label = try createLabel(&panel, 18, 106, Theme.muted),
                .tx_label = try createLabel(&panel, 18, 136, Theme.tx),
                .rx_label = try createLabel(&panel, 18, 162, Theme.rx),
                .error_label = try createLabel(&panel, 218, 54, Theme.quiet),
                .overlay_label = overlay_label,
            };
        }

        pub fn setState(self: *Screen, state: State, runtime_overlay: RuntimeOverlay) void {
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
            self.setOverlay(runtime_overlay);
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

        fn setOverlay(self: *Screen, runtime_overlay: RuntimeOverlay) void {
            const idle0 = if (runtime_overlay.cpu_valid and runtime_overlay.cpu_core_count > 0)
                runtime_overlay.idle_percent[0]
            else
                0;
            const idle1 = if (runtime_overlay.cpu_valid and runtime_overlay.cpu_core_count > 1)
                runtime_overlay.idle_percent[1]
            else
                0;
            const diram_free = if (runtime_overlay.memory_valid) runtime_overlay.diram_free else 0;
            const psram_free = if (runtime_overlay.memory_valid) runtime_overlay.psram_free else 0;

            const len = formatOverlay(self.overlay_text[0 .. self.overlay_text.len - 1], idle0, idle1, diram_free, psram_free);
            self.overlay_text[len] = 0;
            self.overlay_label.setText(self.overlay_text[0..len :0]);
        }

        fn formatOverlay(out: []u8, idle0: u8, idle1: u8, diram_free: usize, psram_free: usize) usize {
            const diram_text = formatBytes(diram_free);
            const psram_text = formatBytes(psram_free);
            const written = glib.std.fmt.bufPrint(
                out,
                "idle0 = {d}%\nidle1 = {d}%\nDIRAM free = {s}\nPSRAM free = {s}",
                .{
                    idle0,
                    idle1,
                    diram_text.slice(),
                    psram_text.slice(),
                },
            ) catch |err| switch (err) {
                error.NoSpaceLeft => out,
            };
            return written.len;
        }

        fn formatBytes(bytes: usize) ByteText {
            const mib = 1024 * 1024;
            const kib = 1024;
            var text: ByteText = .{};
            if (bytes >= mib) {
                const tenths = @divTrunc(bytes * 10 + mib / 2, mib);
                text.set("{d}.{d}MiB", .{ @divTrunc(tenths, 10), @mod(tenths, 10) });
                return text;
            }
            text.set("{d}KiB", .{@divTrunc(bytes + kib / 2, kib)});
            return text;
        }

        const ByteText = struct {
            buf: [16]u8 = [_]u8{0} ** 16,
            len: usize = 0,

            fn set(self: *ByteText, comptime fmt: []const u8, args: anytype) void {
                const written = glib.std.fmt.bufPrint(self.buf[0..], fmt, args) catch unreachable;
                self.len = written.len;
            }

            fn slice(self: *const ByteText) []const u8 {
                return self.buf[0..self.len];
            }
        };
    };
}
