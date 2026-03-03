//! Display HAL wrapper.

const std = @import("std");
const hal_marker = @import("marker.zig");

pub const Error = error{
    OutOfBounds,
    Busy,
    Timeout,
    DisplayError,
};

/// RGB565 (0bRRRRRGGGGGGBBBBB)
pub const Color565 = u16;

pub fn rgb565(r: u8, g: u8, b: u8) Color565 {
    const rr: u16 = @intCast((@as(u16, r) >> 3) & 0x1F);
    const gg: u16 = @intCast((@as(u16, g) >> 2) & 0x3F);
    const bb: u16 = @intCast((@as(u16, b) >> 3) & 0x1F);
    return (rr << 11) | (gg << 5) | bb;
}

pub fn is(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (!@hasDecl(T, "_hal_marker")) return false;
    const marker = T._hal_marker;
    if (@TypeOf(marker) != hal_marker.Marker) return false;
    return marker.kind == .display;
}

/// spec must define:
/// - Driver.width(*const Driver) u16
/// - Driver.height(*const Driver) u16
/// - Driver.drawPixel(*Driver, x: u16, y: u16, color: Color565) Error!void
/// - Driver.clear(*Driver, color: Color565) Error!void
/// - Driver.flush(*Driver) Error!void
/// - meta.id
pub fn from(comptime spec: type) type {
    const BaseDriver = comptime switch (@typeInfo(spec.Driver)) {
        .pointer => |p| p.child,
        else => spec.Driver,
    };

    comptime {
        _ = @as(*const fn (*const BaseDriver) u16, &BaseDriver.width);
        _ = @as(*const fn (*const BaseDriver) u16, &BaseDriver.height);
        _ = @as(*const fn (*BaseDriver, u16, u16, Color565) Error!void, &BaseDriver.drawPixel);
        _ = @as(*const fn (*BaseDriver, Color565) Error!void, &BaseDriver.clear);
        _ = @as(*const fn (*BaseDriver) Error!void, &BaseDriver.flush);

        _ = @as([]const u8, spec.meta.id);
    }

    const Driver = spec.Driver;
    return struct {
        const Self = @This();

        pub const _hal_marker: hal_marker.Marker = .{
            .kind = .display,
            .id = spec.meta.id,
        };
        pub const DriverType = Driver;
        pub const meta = spec.meta;

        driver: *Driver,

        pub fn init(driver: *Driver) Self {
            return .{ .driver = driver };
        }

        pub fn width(self: *const Self) u16 {
            return self.driver.width();
        }

        pub fn height(self: *const Self) u16 {
            return self.driver.height();
        }

        pub fn clear(self: *Self, color: Color565) Error!void {
            return self.driver.clear(color);
        }

        pub fn drawPixel(self: *Self, x: u16, y: u16, color: Color565) Error!void {
            if (x >= self.width() or y >= self.height()) return error.OutOfBounds;
            return self.driver.drawPixel(x, y, color);
        }

        pub fn fillRect(self: *Self, x: u16, y: u16, w: u16, h: u16, color: Color565) Error!void {
            const max_x = @min(@as(u32, x) + w, self.width());
            const max_y = @min(@as(u32, y) + h, self.height());

            var yy: u32 = y;
            while (yy < max_y) : (yy += 1) {
                var xx: u32 = x;
                while (xx < max_x) : (xx += 1) {
                    try self.driver.drawPixel(@intCast(xx), @intCast(yy), color);
                }
            }
        }

        pub fn flush(self: *Self) Error!void {
            return self.driver.flush();
        }
    };
}

test "display wrapper" {
    const Mock = struct {
        const W: u16 = 8;
        const H: u16 = 4;

        fb: [W * H]Color565 = [_]Color565{0} ** (W * H),

        pub fn width(_: *const @This()) u16 {
            return W;
        }
        pub fn height(_: *const @This()) u16 {
            return H;
        }
        pub fn drawPixel(self: *@This(), x: u16, y: u16, color: Color565) Error!void {
            self.fb[y * W + x] = color;
        }
        pub fn clear(self: *@This(), color: Color565) Error!void {
            for (&self.fb) |*px| px.* = color;
        }
        pub fn flush(_: *@This()) Error!void {}
    };

    const Display = from(struct {
        pub const Driver = Mock;
        pub const meta = .{ .id = "display.test" };
    });

    var d = Mock{};
    var display = Display.init(&d);

    try display.clear(rgb565(0, 0, 0));
    try display.drawPixel(1, 1, rgb565(255, 0, 0));
    try std.testing.expectError(error.OutOfBounds, display.drawPixel(100, 1, 0));
    try display.fillRect(0, 0, 2, 2, rgb565(0, 255, 0));
    try std.testing.expect(d.fb[0] != 0);
}
