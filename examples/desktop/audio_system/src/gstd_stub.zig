const glib = @import("glib");

pub const runtime = struct {
    pub const std = @import("std");
    pub const time = glib.time;
};
