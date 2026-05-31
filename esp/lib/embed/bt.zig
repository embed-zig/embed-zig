const Host = @import("bt/Host.zig");

pub const Local = Host.make(@import("bt/LocalHci.zig"));
pub const Remote = Host.make(@import("bt/RemoteHci.zig"));
