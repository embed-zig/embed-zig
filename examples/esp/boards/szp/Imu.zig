const embed = @import("embed");
const esp = @import("esp");
const binding = @import("bindings/common.zig");

const Imu = @This();
const Qmi8658 = embed.drivers.imu.Qmi8658;

const qmi8658_address = @intFromEnum(Qmi8658.Address.sa0_low);

const DelayImpl = struct {
    fn sleep(_: *DelayImpl, duration: esp.grt.time.duration.Duration) void {
        esp.grt.std.Thread.sleep(duration);
    }
};

native_imu: ?Qmi8658 = null,
delay: DelayImpl = .{},

pub fn init(self: *Imu) !void {
    if (self.native_imu != null) return;

    const i2c = try binding.i2cDevice(qmi8658_address);
    self.native_imu = Qmi8658.init(i2c, embed.drivers.Delay.init(&self.delay), .{
        .address = qmi8658_address,
    });
    try self.native_imu.?.open();
}

pub fn handle(self: *Imu) embed.drivers.imu {
    if (self.native_imu) |*imu| {
        return embed.drivers.imu.fromQMI8658(imu);
    }
    @panic("szp imu not initialized");
}
