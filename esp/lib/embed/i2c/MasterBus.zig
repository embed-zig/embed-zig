const embed = @import("embed_core");
const binding = @import("binding.zig");
const Device = @import("Device.zig");

const MasterBus = @This();
const max_devices = 8;
const max_ports = 8;

var port_buses: [max_ports]binding.Handle = [_]binding.Handle{null} ** max_ports;
var port_bus_refs: [max_ports]usize = [_]usize{0} ** max_ports;
var port_bus_owned: [max_ports]bool = [_]bool{false} ** max_ports;

config: Config,
bus: binding.Handle = null,
owns_bus: bool = false,
bus_index: ?usize = null,
devices: [max_devices]Device = [_]Device{.{}} ** max_devices,

pub const Config = struct {
    port: i32,
    sda_io_num: i32,
    scl_io_num: i32,
    scl_speed_hz: u32 = 400_000,
    glitch_ignore_cnt: u32 = 7,
    enable_internal_pullup: bool = true,
};

pub fn init(config: Config) MasterBus {
    return .{ .config = config };
}

pub fn open(self: *MasterBus) embed.drivers.I2c.Error!void {
    if (self.bus != null) return;

    var bus: binding.Handle = null;
    const index = try portIndex(self.config.port);
    if (port_buses[index]) |existing| {
        self.bus = existing;
        self.owns_bus = false;
        self.bus_index = index;
        port_bus_refs[index] += 1;
        return;
    }

    const create_rc = binding.espz_embed_i2c_new_master_bus(
        self.config.port,
        self.config.sda_io_num,
        self.config.scl_io_num,
        self.config.glitch_ignore_cnt,
        self.config.enable_internal_pullup,
        &bus,
    );
    if (binding.isInvalidState(create_rc)) {
        try binding.check(binding.espz_embed_i2c_master_get_bus_handle(self.config.port, &bus));
        self.bus = bus;
        self.owns_bus = false;
        self.bus_index = index;
        port_buses[index] = bus;
        port_bus_refs[index] = 1;
        port_bus_owned[index] = false;
        return;
    }

    try binding.check(create_rc);
    self.bus = bus;
    self.owns_bus = true;
    self.bus_index = index;
    port_buses[index] = bus;
    port_bus_refs[index] = 1;
    port_bus_owned[index] = true;
}

pub fn deinit(self: *MasterBus) void {
    for (&self.devices) |*slot| {
        if (slot.handle) |handle| {
            _ = binding.espz_embed_i2c_master_bus_rm_device(handle);
            slot.* = .{};
        }
    }
    if (self.bus) |bus| {
        if (self.bus_index) |index| {
            releasePortBus(index, bus);
        } else if (self.owns_bus) {
            _ = binding.espz_embed_i2c_del_master_bus(bus);
        }
    }
    self.bus = null;
    self.owns_bus = false;
    self.bus_index = null;
}

pub fn device(self: *MasterBus, address: embed.drivers.I2c.Address) embed.drivers.I2c.Error!embed.drivers.I2c {
    const slot = try self.deviceSlot(address);
    return embed.drivers.I2c.init(slot);
}

fn deviceSlot(self: *MasterBus, address: embed.drivers.I2c.Address) embed.drivers.I2c.Error!*Device {
    const bus = self.bus orelse return error.BusError;

    var first_empty: ?usize = null;
    for (&self.devices, 0..) |*slot, index| {
        if (slot.handle == null) {
            if (first_empty == null) first_empty = index;
            continue;
        }
        if (slot.address == address) return slot;
    }

    const index = first_empty orelse return error.Unexpected;
    var handle: binding.Handle = null;
    try binding.check(binding.espz_embed_i2c_master_bus_add_device(
        bus,
        address,
        self.config.scl_speed_hz,
        &handle,
    ));
    self.devices[index] = .{
        .address = address,
        .handle = handle,
    };
    return &self.devices[index];
}

fn portIndex(port: i32) embed.drivers.I2c.Error!usize {
    if (port < 0) return error.BusError;
    const index: usize = @intCast(port);
    if (index >= max_ports) return error.BusError;
    return index;
}

fn releasePortBus(index: usize, bus: binding.Handle) void {
    if (port_buses[index] != bus or port_bus_refs[index] == 0) return;

    port_bus_refs[index] -= 1;
    if (port_bus_refs[index] != 0) return;

    port_buses[index] = null;
    const should_delete = port_bus_owned[index];
    port_bus_owned[index] = false;
    if (should_delete) {
        _ = binding.espz_embed_i2c_del_master_bus(bus);
    }
}
