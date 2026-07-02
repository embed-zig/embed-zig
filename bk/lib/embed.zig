const embed_core = @import("embed_core");

pub const std = @import("bk.zig").ap.grt.std;
pub const audio = embed_core.audio;
pub const audio_adapter = @import("embed/audio.zig");
pub const board = embed_core.board;
pub const bt = @import("embed/bt.zig");
pub const drivers = embed_core.drivers;
pub const ledstrip = embed_core.ledstrip;
pub const motion = embed_core.motion;
pub const system = @import("embed/system.zig");
pub const zux = embed_core.zux;

pub const display = @import("embed/display.zig");
pub const gpio = @import("embed/gpio.zig");
pub const saradc = @import("embed/saradc.zig");
pub const touch = @import("embed/touch.zig");
pub const Wifi = @import("embed/Wifi.zig");
