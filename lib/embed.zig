const runtime = @import("runtime");

pub const Options = runtime.Options;
pub const std = @import("stdz");
pub const testing = @import("testing");
pub const context = @import("context");
pub const sync = @import("sync");
pub const io = @import("io");
pub const drivers = @import("drivers");
pub const net = @import("net");
pub const mime = @import("mime");
pub const bt = @import("bt");
pub const motion = @import("motion");
pub const audio = @import("audio");
pub const ledstrip = @import("ledstrip");
pub const zux = @import("zux");

pub fn make(comptime options: Options) type {
    return runtime.make(options);
}

pub fn is(comptime ns: type) bool {
    return runtime.isRuntime(ns);
}
