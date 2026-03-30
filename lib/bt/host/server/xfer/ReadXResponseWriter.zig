//! host.server.xfer.ReadXResponseWriter — logical read_x response writer.

_impl: *anyopaque,
_write_fn: *const fn (*anyopaque, []const u8) void,
_err_fn: *const fn (*anyopaque, u8) void,

pub fn write(self: *@This(), data: []const u8) void {
    self._write_fn(self._impl, data);
}

pub fn err(self: *@This(), code: u8) void {
    self._err_fn(self._impl, code);
}
