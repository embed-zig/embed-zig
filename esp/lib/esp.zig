pub const glib = @import("glib");
const esp_grt = @import("esp_grt");
const grt_mod = esp_grt.runtime;

pub const idf = @import("esp_idf");
pub const embed = @import("esp_embed");
pub const heap = @import("esp_heap");
pub const Launcher = @import("Launcher.zig");
pub const net = @import("net.zig");

pub const grt = glib.runtime.make(grt_mod);
pub const net_runtime = esp_grt.net.Runtime;
pub const native_task = esp_grt.task.Native;
pub const fs = esp_grt.fs;
