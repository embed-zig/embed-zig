const embed = @import("embed_core");
const esp = @import("esp");
const binding = @import("bindings/common.zig");

const Touch = @This();
const Gt911 = embed.drivers.Touch.Gt911;

const log = esp.grt.std.log.scoped(.wv_p4_touch);
const touch_width: u16 = 480;
const touch_height: u16 = 800;

native_touch: ?Gt911 = null,

pub fn init(self: *Touch) !void {
    if (self.native_touch != null) return;

    if (self.openAt(Gt911.default_address)) |_| {
        log.info("gt911 touch initialized at 0x{x}", .{Gt911.default_address});
        return;
    } else |default_err| {
        log.warn("gt911 default address 0x{x} failed: {s}", .{ Gt911.default_address, @errorName(default_err) });
    }

    try self.openAt(Gt911.backup_address);
    log.info("gt911 touch initialized at 0x{x}", .{Gt911.backup_address});
}

pub fn handle(self: *Touch) embed.drivers.Touch {
    if (self.native_touch) |*touch| {
        return touch.asTouch();
    }
    @panic("wv esp32p4 wifi6 touch lcd touch not initialized");
}

fn openAt(self: *Touch, address: embed.drivers.I2c.Address) !void {
    const i2c = try binding.i2cDevice(address);
    self.native_touch = Gt911.init(i2c, .{
        .address = address,
        .transform = .{
            .width = touch_width,
            .height = touch_height,
        },
    });
    errdefer self.native_touch = null;
    try self.native_touch.?.open();
}
