const glib = @import("glib");

pub const default = "internet";

pub fn detectFromImsi(imsi_value: []const u8) ?[]const u8 {
    if (startsWithAny(imsi_value, &.{ "46000", "46002", "46004", "46007", "46008", "46013" })) {
        return "cmiot";
    }
    if (startsWithAny(imsi_value, &.{ "46001", "46006", "46009" })) {
        return "3gnet";
    }
    if (startsWithAny(imsi_value, &.{ "46003", "46005", "46011" })) {
        return "ctnet";
    }
    return null;
}

pub fn detectApn(imsi_value: []const u8) []const u8 {
    return detectFromImsi(imsi_value) orelse default;
}

fn startsWithAny(value: []const u8, prefixes: []const []const u8) bool {
    for (prefixes) |prefix| {
        if (glib.std.mem.startsWith(u8, value, prefix)) return true;
    }
    return false;
}
