const binding = @import("binding.zig");
const types = @import("types.zig");

const Self = @This();

index: types.HostApiIndex,
info: *const binding.PaHostApiInfo,

pub fn wrap(index: types.HostApiIndex, info: *const binding.PaHostApiInfo) Self {
    return .{
        .index = index,
        .info = info,
    };
}

pub fn name(self: Self) [*:0]const u8 {
    return self.info.name;
}

pub fn deviceCount(self: Self) u32 {
    return @intCast(self.info.deviceCount);
}

pub fn defaultInputDevice(self: Self) types.DeviceIndex {
    return self.info.defaultInputDevice;
}

pub fn defaultOutputDevice(self: Self) types.DeviceIndex {
    return self.info.defaultOutputDevice;
}

test "portaudio/unit_tests/host_api/wraps_host_api_info" {
    const std = @import("std");
    const testing = std.testing;

    var info = binding.PaHostApiInfo{
        .structVersion = 1,
        .type = 0,
        .name = "core",
        .deviceCount = 3,
        .defaultInputDevice = 1,
        .defaultOutputDevice = 2,
    };
    const api = wrap(0, &info);

    try testing.expectEqual(@as(types.HostApiIndex, 0), api.index);
    try testing.expectEqual(@as(u32, 3), api.deviceCount());
    try testing.expectEqual(@as(types.DeviceIndex, 1), api.defaultInputDevice());
    try testing.expectEqual(@as(types.DeviceIndex, 2), api.defaultOutputDevice());
}
