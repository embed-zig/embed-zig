//! I2S HAL contract wrapper (bus + endpoint model).
//!
//! This module models I2S as:
//! - one controller/bus instance
//! - one or more registered endpoints (RX / TX)
//!
//! The intent is to avoid each peripheral (mic/speaker) directly owning the
//! hardware port and accidentally conflicting on init order or configuration.

pub const Error = error{
    InitFailed,
    Busy,
    Timeout,
    InvalidParam,
    InvalidDirection,
    I2sError,
};

pub const Role = enum {
    master,
    slave,
};

pub const Mode = enum {
    std,
    tdm,
};

pub const SlotMode = enum {
    mono,
    stereo,
};

pub const BitsPerSample = enum {
    bits16,
    bits24,
    bits32,
};

pub const Direction = enum {
    rx,
    tx,
};

pub const BusConfig = struct {
    port: u8 = 0,
    role: Role = .master,
    mode: Mode = .std,
    slot_mode: SlotMode = .stereo,
    bits_per_sample: BitsPerSample = .bits16,
    sample_rate_hz: u32 = 16_000,
    tdm_slot_mask: u32 = 0,
    mclk: i32 = -1,
    bclk: i32,
    ws: i32,
    dma_desc_num: u16 = 6,
    dma_frame_num: u16 = 240,
};

pub const EndpointConfig = struct {
    direction: Direction,
    data_pin: i32,
    timeout_ms: u32 = 20,
};

/// spec must define:
/// - Driver type
/// - EndpointHandle type in `spec.EndpointHandle`
/// - Driver.initBus(BusConfig) Error!Driver
/// - Driver.deinitBus(*Driver) void (or optional)
/// - Driver.registerEndpoint(*Driver, EndpointConfig) Error!EndpointHandle
/// - Driver.unregisterEndpoint(*Driver, EndpointHandle) Error!void
/// - Driver.read(*Driver, EndpointHandle, []u8) Error!usize
/// - Driver.write(*Driver, EndpointHandle, []const u8) Error!usize
/// - meta.id: []const u8
pub fn from(comptime spec: type) type {
    const BaseDriver = comptime switch (@typeInfo(spec.Driver)) {
        .pointer => |p| p.child,
        else => spec.Driver,
    };

    const EndpointHandle = comptime if (@hasDecl(spec, "EndpointHandle"))
        spec.EndpointHandle
    else
        @compileError("i2s spec requires EndpointHandle");

    comptime {
        _ = @as(*const fn (BusConfig) Error!BaseDriver, &BaseDriver.initBus);
        _ = @as(*const fn (*BaseDriver, EndpointConfig) Error!EndpointHandle, &BaseDriver.registerEndpoint);
        _ = @as(*const fn (*BaseDriver, EndpointHandle) Error!void, &BaseDriver.unregisterEndpoint);
        _ = @as(*const fn (*BaseDriver, EndpointHandle, []u8) Error!usize, &BaseDriver.read);
        _ = @as(*const fn (*BaseDriver, EndpointHandle, []const u8) Error!usize, &BaseDriver.write);
        _ = @as([]const u8, spec.meta.id);
    }

    const Driver = spec.Driver;
    return struct {
        const Self = @This();

        pub const DriverType = Driver;
        pub const EndpointHandleType = EndpointHandle;
        pub const meta = spec.meta;

        pub const Endpoint = struct {
            driver: *Driver,
            handle: EndpointHandle,
            direction: Direction,
            timeout_ms: u32,
            active: bool = true,

            pub fn deinit(self: *Endpoint) void {
                if (!self.active) return;
                self.driver.unregisterEndpoint(self.handle) catch {};
                self.active = false;
            }

            pub fn read(self: *Endpoint, out: []u8) Error!usize {
                if (!self.active) return error.InvalidParam;
                if (self.direction != .rx) return error.InvalidDirection;
                return self.driver.read(self.handle, out);
            }

            pub fn write(self: *Endpoint, input: []const u8) Error!usize {
                if (!self.active) return error.InvalidParam;
                if (self.direction != .tx) return error.InvalidDirection;
                return self.driver.write(self.handle, input);
            }

            pub fn readI16(self: *Endpoint, out: []i16) Error!usize {
                const bytes = @import("std").mem.sliceAsBytes(out);
                const n = try self.read(bytes);
                return n / @sizeOf(i16);
            }

            pub fn writeI16(self: *Endpoint, input: []const i16) Error!usize {
                const bytes = @import("std").mem.sliceAsBytes(input);
                const n = try self.write(bytes);
                return n / @sizeOf(i16);
            }
        };

        driver: Driver,

        pub fn initBus(cfg: BusConfig) Error!Self {
            const driver = try Driver.initBus(cfg);
            return .{ .driver = driver };
        }

        pub fn deinitBus(self: *Self) void {
            if (comptime @hasDecl(Driver, "deinitBus")) {
                self.driver.deinitBus();
            } else if (comptime @hasDecl(Driver, "deinit")) {
                self.driver.deinit();
            }
        }

        pub fn register(self: *Self, cfg: EndpointConfig) Error!Endpoint {
            const handle = try self.driver.registerEndpoint(cfg);
            return .{
                .driver = &self.driver,
                .handle = handle,
                .direction = cfg.direction,
                .timeout_ms = cfg.timeout_ms,
            };
        }

        pub fn openRx(self: *Self, data_pin: i32, timeout_ms: u32) Error!Endpoint {
            return self.register(.{
                .direction = .rx,
                .data_pin = data_pin,
                .timeout_ms = timeout_ms,
            });
        }

        pub fn openTx(self: *Self, data_pin: i32, timeout_ms: u32) Error!Endpoint {
            return self.register(.{
                .direction = .tx,
                .data_pin = data_pin,
                .timeout_ms = timeout_ms,
            });
        }
    };
}
