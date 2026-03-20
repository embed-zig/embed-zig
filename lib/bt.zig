pub const Central = @import("bt/Central.zig");
pub const Peripheral = @import("bt/Peripheral.zig");
pub const Transport = @import("bt/Transport.zig");
pub const test_runner = struct {
    pub const central = @import("bt/test_runner/central.zig");
    pub const peripheral = @import("bt/test_runner/peripheral.zig");
};

/// Build Central/Peripheral from a raw HCI Transport (host stack).
///
///   var h4 = H4Uart.init(&uart);
///   var transport = bt.Transport.init(&h4);
///   const host = bt.Make(transport);
///   var central = host.central();
///   var peripheral = host.peripheral();
pub fn Make(comptime transport: Transport) type {
    _ = transport;
    @compileError("bt.Make: host stack not yet implemented");
}

test {
    _ = Central;
    _ = Peripheral;
    _ = Transport;
    _ = test_runner;
}
