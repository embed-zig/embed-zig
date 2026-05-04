const glib = @import("glib");
const grt_mod = @import("esp_grt").runtime;

pub const idf = @import("esp_idf");
pub const heap = @import("esp_heap");

pub const grt = glib.runtime.make(grt_mod);
