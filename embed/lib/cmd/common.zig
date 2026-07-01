const Executor = @import("Executor.zig");
const Output = @import("Output.zig");

pub const Options = struct {
    version: []const u8 = "unsupported",
};

pub fn registerMinimal(registry: *Executor.Registry, options: Options) !void {
    registry.setVersion(options.version);
    try registry.addCommand(.{
        .name = "help",
        .desc = "list commands",
        .handler = help,
        .ctx = registry,
    });
    try registry.addCommand(.{
        .name = "ping",
        .desc = "check command liveness",
        .handler = ping,
    });
    try registry.addCommand(.{
        .name = "version",
        .desc = "print version",
        .handler = version,
        .ctx = registry,
    });
}

pub fn registerPing(executor: Executor) !void {
    try executor.addCommand(.{
        .name = "ping",
        .desc = "check command liveness",
        .handler = ping,
    });
}

pub fn ping(_: ?*anyopaque, args: []const u8, out: Output) !void {
    _ = args;
    try out.writeAll("pong\n");
}

pub fn version(ctx: ?*anyopaque, args: []const u8, out: Output) !void {
    _ = args;
    const registry: *Executor.Registry = @ptrCast(@alignCast(ctx.?));
    try out.writeAll(registry.getVersion());
    try out.writeAll("\n");
}

pub fn help(ctx: ?*anyopaque, args: []const u8, out: Output) !void {
    _ = args;
    const registry: *Executor.Registry = @ptrCast(@alignCast(ctx.?));
    for (registry.commandList()) |command| {
        try out.writeAll(command.name);
        if (command.desc.len != 0) {
            try out.writeAll(" - ");
            try out.writeAll(command.desc);
        }
        try out.writeAll("\n");
    }
}
