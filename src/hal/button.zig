//! Button HAL wrapper (single button).

const std = @import("std");
const hal_marker = @import("marker.zig");

pub const ButtonAction = enum {
    press,
    release,
    click,
    double_click,
    long_press,
};

pub const Event = struct {
    source: []const u8,
    action: ButtonAction,
    timestamp_ms: u64,
    click_count: u8 = 1,
    duration_ms: u32 = 0,
};

pub const Config = struct {
    debounce_ms: u32 = 20,
    long_press_ms: u32 = 1000,
    double_click_ms: u32 = 300,
    detect_clicks: bool = true,
    detect_double_click: bool = true,
};

pub fn is(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (!@hasDecl(T, "_hal_marker")) return false;
    const marker = T._hal_marker;
    if (@TypeOf(marker) != hal_marker.Marker) return false;
    return marker.kind == .button;
}

/// spec must define:
/// - Driver.isPressed(*Driver) bool
/// - meta.id
///
/// optional:
/// - config: Config
pub fn from(comptime spec: type) type {
    const has_spec_config = comptime @hasDecl(spec, "config");

    comptime {
        const BaseDriver = switch (@typeInfo(spec.Driver)) {
            .pointer => |p| p.child,
            else => spec.Driver,
        };

        _ = @as(*const fn (*BaseDriver) bool, &BaseDriver.isPressed);
        _ = @as([]const u8, spec.meta.id);
        if (has_spec_config) {
            _ = @as(Config, spec.config);
        }
    }

    const Driver = spec.Driver;
    return struct {
        const Self = @This();

        pub const _hal_marker: hal_marker.Marker = .{
            .kind = .button,
            .id = spec.meta.id,
        };
        pub const DriverType = Driver;
        pub const meta = spec.meta;
        pub const config: Config = if (has_spec_config) spec.config else .{};

        driver: *Driver,

        state: enum { idle, debouncing, pressed } = .idle,
        last_raw: bool = false,
        debounce_start_ms: u64 = 0,
        press_start_ms: u64 = 0,
        release_time_ms: u64 = 0,
        long_press_fired: bool = false,
        pending_click: bool = false,

        pub fn init(driver: *Driver) Self {
            return .{ .driver = driver };
        }

        pub fn isPressed(self: *const Self) bool {
            return self.state == .pressed;
        }

        /// Poll button state with monotonic timestamp (ms).
        pub fn poll(self: *Self, now_ms: u64) ?Event {
            const raw = self.driver.isPressed();

            switch (self.state) {
                .idle => {
                    if (raw and !self.last_raw) {
                        self.state = .debouncing;
                        self.debounce_start_ms = now_ms;
                    } else if (self.pending_click and now_ms >= self.release_time_ms + config.double_click_ms) {
                        self.pending_click = false;
                        self.last_raw = raw;
                        return .{
                            .source = meta.id,
                            .action = .click,
                            .timestamp_ms = self.release_time_ms,
                            .click_count = 1,
                        };
                    }
                },

                .debouncing => {
                    if (now_ms >= self.debounce_start_ms + config.debounce_ms) {
                        if (raw) {
                            self.state = .pressed;
                            self.press_start_ms = now_ms;
                            self.long_press_fired = false;
                            self.last_raw = raw;
                            return .{ .source = meta.id, .action = .press, .timestamp_ms = now_ms };
                        }
                        self.state = .idle;
                    }
                },

                .pressed => {
                    if (!raw) {
                        const duration = satMs(now_ms, self.press_start_ms);
                        self.release_time_ms = now_ms;

                        if (config.detect_double_click and self.pending_click) {
                            self.pending_click = false;
                            self.state = .idle;
                            self.last_raw = raw;
                            return .{
                                .source = meta.id,
                                .action = .double_click,
                                .timestamp_ms = now_ms,
                                .click_count = 2,
                                .duration_ms = duration,
                            };
                        }

                        if (config.detect_clicks and config.detect_double_click) {
                            self.pending_click = true;
                            self.state = .idle;
                            self.last_raw = raw;
                            return .{
                                .source = meta.id,
                                .action = .release,
                                .timestamp_ms = now_ms,
                                .duration_ms = duration,
                            };
                        }

                        if (config.detect_clicks) {
                            self.state = .idle;
                            self.last_raw = raw;
                            return .{
                                .source = meta.id,
                                .action = .click,
                                .timestamp_ms = now_ms,
                                .click_count = 1,
                                .duration_ms = duration,
                            };
                        }

                        self.state = .idle;
                        self.last_raw = raw;
                        return .{
                            .source = meta.id,
                            .action = .release,
                            .timestamp_ms = now_ms,
                            .duration_ms = duration,
                        };
                    }

                    if (!self.long_press_fired and now_ms >= self.press_start_ms + config.long_press_ms) {
                        self.long_press_fired = true;
                        self.last_raw = raw;
                        return .{
                            .source = meta.id,
                            .action = .long_press,
                            .timestamp_ms = now_ms,
                            .duration_ms = satMs(now_ms, self.press_start_ms),
                        };
                    }
                },
            }

            self.last_raw = raw;
            return null;
        }

        pub fn reset(self: *Self) void {
            self.state = .idle;
            self.last_raw = false;
            self.debounce_start_ms = 0;
            self.press_start_ms = 0;
            self.release_time_ms = 0;
            self.long_press_fired = false;
            self.pending_click = false;
        }

        fn satMs(now: u64, start: u64) u32 {
            const raw = if (now >= start) now - start else 0;
            return @intCast(@min(raw, std.math.maxInt(u32)));
        }
    };
}

test "button click and double-click" {
    const Mock = struct {
        pressed: bool = false,
        pub fn isPressed(self: *@This()) bool {
            return self.pressed;
        }
    };

    const Button = from(struct {
        pub const Driver = Mock;
        pub const meta = .{ .id = "btn.test" };
        pub const config = Config{ .debounce_ms = 5, .double_click_ms = 200, .long_press_ms = 500 };
    });

    var d = Mock{};
    var btn = Button.init(&d);

    // first press
    d.pressed = true;
    try std.testing.expect(btn.poll(0) == null);
    const e1 = btn.poll(10) orelse return error.ExpectedPress;
    try std.testing.expectEqual(ButtonAction.press, e1.action);

    // first release
    d.pressed = false;
    const e2 = btn.poll(30) orelse return error.ExpectedRelease;
    try std.testing.expectEqual(ButtonAction.release, e2.action);

    // second press
    d.pressed = true;
    _ = btn.poll(80);
    _ = btn.poll(90);

    // second release -> double click
    d.pressed = false;
    const e3 = btn.poll(120) orelse return error.ExpectedDoubleClick;
    try std.testing.expectEqual(ButtonAction.double_click, e3.action);
}

test "button long press" {
    const Mock = struct {
        pressed: bool = false,
        pub fn isPressed(self: *@This()) bool {
            return self.pressed;
        }
    };

    const Button = from(struct {
        pub const Driver = Mock;
        pub const meta = .{ .id = "btn.long" };
        pub const config = Config{ .debounce_ms = 5, .long_press_ms = 100, .detect_clicks = false };
    });

    var d = Mock{};
    var btn = Button.init(&d);

    d.pressed = true;
    _ = btn.poll(0);
    _ = btn.poll(10);
    const ev = btn.poll(120) orelse return error.ExpectedLongPress;
    try std.testing.expectEqual(ButtonAction.long_press, ev.action);
}
