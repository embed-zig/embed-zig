const embed = @import("embed");
const binding = @import("binding.zig");

const Device = @This();

address: embed.drivers.I2c.Address = 0,
handle: binding.Handle = null,

pub fn write(
    self: *Device,
    address: embed.drivers.I2c.Address,
    data: []const u8,
) embed.drivers.I2c.Error!void {
    try self.checkAddress(address);
    try binding.check(binding.espz_embed_i2c_master_transmit(self.handle.?, data.ptr, data.len, binding.default_timeout_ms));
}

pub fn read(
    self: *Device,
    address: embed.drivers.I2c.Address,
    buf: []u8,
) embed.drivers.I2c.Error!void {
    try self.checkAddress(address);
    try binding.check(binding.espz_embed_i2c_master_receive(self.handle.?, buf.ptr, buf.len, binding.default_timeout_ms));
}

pub fn writeRead(
    self: *Device,
    address: embed.drivers.I2c.Address,
    tx: []const u8,
    rx: []u8,
) embed.drivers.I2c.Error!void {
    try self.checkAddress(address);
    try binding.check(binding.espz_embed_i2c_master_transmit_receive(
        self.handle.?,
        tx.ptr,
        tx.len,
        rx.ptr,
        rx.len,
        binding.default_timeout_ms,
    ));
}

fn checkAddress(
    self: *const Device,
    address: embed.drivers.I2c.Address,
) embed.drivers.I2c.Error!void {
    if (self.handle == null) return error.BusError;
    if (address != self.address) return error.BusError;
}
