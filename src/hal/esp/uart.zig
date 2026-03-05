const esp = @import("esp");
const hal_uart = @import("hal").uart;

pub const Driver = struct {
    port: i32 = 0,
    timeout_ms: u32 = 0,

    pub fn init() hal_uart.Error!Driver {
        esp.esp_driver_uart.init(.{}) catch return error.UartError;
        return .{};
    }

    pub fn initConfig(cfg: esp.esp_driver_uart.Config, timeout_ms: u32) hal_uart.Error!Driver {
        esp.esp_driver_uart.init(cfg) catch return error.UartError;
        return .{
            .port = cfg.port,
            .timeout_ms = timeout_ms,
        };
    }

    pub fn deinit(self: *Driver) void {
        esp.esp_driver_uart.deinit(self.port) catch {};
    }

    pub fn read(self: *Driver, buf: []u8) hal_uart.Error!usize {
        const n = esp.esp_driver_uart.read(self.port, buf, self.timeout_ms) catch return error.UartError;
        if (n == 0) return error.WouldBlock;
        return n;
    }

    pub fn write(self: *Driver, buf: []const u8) hal_uart.Error!usize {
        const n = esp.esp_driver_uart.write(self.port, buf, self.timeout_ms) catch return error.UartError;
        if (n == 0 and buf.len != 0) return error.WouldBlock;
        return n;
    }

    pub fn poll(self: *Driver, flags: hal_uart.PollFlags, _: i32) hal_uart.PollFlags {
        const readable = if (flags.readable) blk: {
            const queued = esp.esp_driver_uart.bufferedLen(self.port) catch break :blk false;
            break :blk queued > 0;
        } else false;

        return .{
            .readable = readable,
            .writable = flags.writable,
        };
    }
};
