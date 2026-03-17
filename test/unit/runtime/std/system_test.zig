const std = @import("std");
const embed = @import("embed");
const System = embed.runtime.std.System;

const std_system: System = .{};

test "std system getCpuCount" {
    const cpu = try std_system.getCpuCount();
    try std.testing.expect(cpu >= 1);
}
