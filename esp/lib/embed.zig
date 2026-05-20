const embed_core = @import("embed_core");

pub const std = @import("esp").grt.std;
pub const audio = embed_core.audio;
pub const board = embed_core.board;
pub const bt = embed_core.bt;
pub const drivers = embed_core.drivers;
pub const ledstrip = embed_core.ledstrip;
pub const motion = embed_core.motion;
pub const zux = embed_core.zux;
pub const BtHost = @import("embed/BtHost.zig");
pub const I2c = @import("embed/I2c.zig");
pub const Wifi = @import("embed/Wifi.zig");
pub const boards = @import("embed/boards.zig");
