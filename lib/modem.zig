//! modem — portable modem abstractions and helpers.

pub const Modem = @import("modem/Modem.zig");
pub const test_runner = struct {
    pub const unit = @import("modem/test_runner/unit.zig");
};

const root = @This();

pub fn make(comptime lib: type) type {
    return struct {
        pub fn makeModem(comptime Impl: type) type {
            return root.Modem.make(lib, Impl);
        }
    };
}
