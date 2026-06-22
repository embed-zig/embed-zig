const common = @import("zux_ble_speed_test_common");

const Impl = common.Make(.server);

pub const role = Impl.role;
pub const SpecType = Impl.SpecType;
pub const make = Impl.make;
pub const testRunner = Impl.testRunner;
pub const run = Impl.run;
