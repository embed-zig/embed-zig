const ledstrip = @import("ledstrip");

pub fn make(comptime Impl: type) type {
    const impl_periph_label = blk: {
        if (!@hasDecl(Impl, "PeriphLabel")) {
            @compileError("zux.App.make requires Impl.PeriphLabel");
        }
        break :blk @as(type, Impl.PeriphLabel);
    };
    const impl_init_config = blk: {
        if (!@hasDecl(Impl, "InitConfig")) {
            @compileError("zux.App.make requires Impl.InitConfig");
        }
        break :blk @as(type, Impl.InitConfig);
    };
    const impl_pixel_count = blk: {
        if (!@hasDecl(Impl, "pixel_count")) {
            @compileError("zux.App.make requires Impl.pixel_count");
        }
        break :blk @as(usize, Impl.pixel_count);
    };
    const impl_frame_type = ledstrip.Frame.make(impl_pixel_count);
    const impl_store_type = if (@hasDecl(Impl, "Store")) Impl.Store else void;

    comptime {
        if (@typeInfo(Impl) != .@"struct") {
            @compileError("zux.App.make requires Impl to be a struct type");
        }
        if (@typeInfo(impl_periph_label) != .@"enum") {
            @compileError("zux.App.make requires Impl.PeriphLabel to be an enum type");
        }

        if (!@hasDecl(Impl, "deinit")) {
            @compileError("zux.App.make requires Impl.deinit");
        }
        if (!@hasDecl(Impl, "init")) {
            @compileError("zux.App.make requires Impl.init");
        }
        if (!@hasDecl(Impl, "start")) {
            @compileError("zux.App.make requires Impl.start");
        }
        if (!@hasDecl(Impl, "stop")) {
            @compileError("zux.App.make requires Impl.stop");
        }
        if (!@hasDecl(Impl, "press_single_button")) {
            @compileError("zux.App.make requires Impl.press_single_button");
        }
        if (!@hasDecl(Impl, "release_single_button")) {
            @compileError("zux.App.make requires Impl.release_single_button");
        }
        if (!@hasDecl(Impl, "press_grouped_button")) {
            @compileError("zux.App.make requires Impl.press_grouped_button");
        }
        if (!@hasDecl(Impl, "release_grouped_button")) {
            @compileError("zux.App.make requires Impl.release_grouped_button");
        }
        if (!@hasDecl(Impl, "set_led_strip_pixels")) {
            @compileError("zux.App.make requires Impl.set_led_strip_pixels");
        }
        if (!@hasDecl(Impl, "set_led_strip_animated")) {
            @compileError("zux.App.make requires Impl.set_led_strip_animated");
        }
        if (!@hasDecl(Impl, "set_led_strip_flash")) {
            @compileError("zux.App.make requires Impl.set_led_strip_flash");
        }
        if (!@hasDecl(Impl, "set_led_strip_pingpong")) {
            @compileError("zux.App.make requires Impl.set_led_strip_pingpong");
        }
        if (!@hasDecl(Impl, "set_led_strip_rotate")) {
            @compileError("zux.App.make requires Impl.set_led_strip_rotate");
        }
        if (impl_store_type != void and !@hasDecl(Impl, "store")) {
            @compileError("zux.App.make requires Impl.store when Impl.Store is present");
        }

        _ = @as(*const fn (impl_init_config) anyerror!Impl, &Impl.init);
        _ = @as(*const fn (*Impl) void, &Impl.deinit);
        _ = @as(*const fn (*Impl) anyerror!void, &Impl.start);
        _ = @as(*const fn (*Impl) anyerror!void, &Impl.stop);
        _ = @as(*const fn (*Impl, impl_periph_label) anyerror!void, &Impl.press_single_button);
        _ = @as(*const fn (*Impl, impl_periph_label) anyerror!void, &Impl.release_single_button);
        _ = @as(*const fn (*Impl, impl_periph_label, u32) anyerror!void, &Impl.press_grouped_button);
        _ = @as(*const fn (*Impl, impl_periph_label) anyerror!void, &Impl.release_grouped_button);
        _ = @as(*const fn (*Impl, impl_periph_label, impl_frame_type, u8) anyerror!void, &Impl.set_led_strip_pixels);
        _ = @as(*const fn (*Impl, impl_periph_label, impl_frame_type, u8, u32) anyerror!void, &Impl.set_led_strip_animated);
        _ = @as(*const fn (*Impl, impl_periph_label, impl_frame_type, u8, u64, u64) anyerror!void, &Impl.set_led_strip_flash);
        _ = @as(*const fn (*Impl, impl_periph_label, impl_frame_type, impl_frame_type, u8, u64, u64) anyerror!void, &Impl.set_led_strip_pingpong);
        _ = @as(*const fn (*Impl, impl_periph_label, impl_frame_type, u8, u64, u64) anyerror!void, &Impl.set_led_strip_rotate);
        if (impl_store_type != void) {
            _ = @as(*const fn (*Impl) *impl_store_type, &Impl.store);
        }
    }

    const app = struct {
        const Self = @This();

        impl: Impl,
        store: if (impl_store_type == void) void else *impl_store_type,

        pub const ImplType = Impl;
        pub const InitConfig = impl_init_config;
        pub const Lib = if (@hasDecl(Impl, "Lib")) Impl.Lib else void;
        pub const Config = if (@hasDecl(Impl, "Config")) Impl.Config else void;
        pub const BuildConfig = if (@hasDecl(Impl, "BuildConfig")) Impl.BuildConfig else void;
        pub const build_config = if (@hasDecl(Impl, "build_config")) Impl.build_config else {};
        pub const Store = if (@hasDecl(Impl, "Store")) Impl.Store else void;
        pub const Root = if (@hasDecl(Impl, "Root")) Impl.Root else void;
        pub const Label = if (@hasDecl(Impl, "Label")) Impl.Label else impl_periph_label;
        pub const PeriphLabel = impl_periph_label;
        pub const poller_count = if (@hasDecl(Impl, "poller_count")) Impl.poller_count else 0;
        pub const pixel_count = impl_pixel_count;
        pub const FrameType = impl_frame_type;

        pub fn init(init_config: InitConfig) !Self {
            var impl = try Impl.init(init_config);
            return .{
                .impl = impl,
                .store = if (impl_store_type == void) {} else impl.store(),
            };
        }

        pub fn deinit(self: *Self) void {
            self.impl.deinit();
        }

        pub fn start(self: *Self) !void {
            try self.impl.start();
        }

        pub fn stop(self: *Self) !void {
            try self.impl.stop();
        }

        pub fn press_single_button(self: *Self, label: PeriphLabel) !void {
            try self.impl.press_single_button(label);
        }

        pub fn release_single_button(self: *Self, label: PeriphLabel) !void {
            try self.impl.release_single_button(label);
        }

        pub fn press_grouped_button(self: *Self, label: PeriphLabel, button_id: u32) !void {
            try self.impl.press_grouped_button(label, button_id);
        }

        pub fn release_grouped_button(self: *Self, label: PeriphLabel) !void {
            try self.impl.release_grouped_button(label);
        }

        pub fn set_led_strip_pixels(self: *Self, label: PeriphLabel, frame: FrameType, brightness: u8) !void {
            try self.impl.set_led_strip_pixels(label, frame, brightness);
        }

        pub fn set_led_strip_animated(
            self: *Self,
            label: PeriphLabel,
            frame: FrameType,
            brightness: u8,
            duration: u32,
        ) !void {
            try self.impl.set_led_strip_animated(label, frame, brightness, duration);
        }

        pub fn set_led_strip_flash(
            self: *Self,
            label: PeriphLabel,
            frame: FrameType,
            brightness: u8,
            duration_ns: u64,
            interval_ns: u64,
        ) !void {
            try self.impl.set_led_strip_flash(label, frame, brightness, duration_ns, interval_ns);
        }

        pub fn set_led_strip_pingpong(
            self: *Self,
            label: PeriphLabel,
            from_frame: FrameType,
            to_frame: FrameType,
            brightness: u8,
            duration_ns: u64,
            interval_ns: u64,
        ) !void {
            try self.impl.set_led_strip_pingpong(label, from_frame, to_frame, brightness, duration_ns, interval_ns);
        }

        pub fn set_led_strip_rotate(
            self: *Self,
            label: PeriphLabel,
            frame: FrameType,
            brightness: u8,
            duration_ns: u64,
            interval_ns: u64,
        ) !void {
            try self.impl.set_led_strip_rotate(label, frame, brightness, duration_ns, interval_ns);
        }
    };

    return app;
}
