const Config = @import("Config.zig");

pub fn make(comptime input: anytype) blk: {
    const Input = @TypeOf(input);

    if (!@hasField(Input, "lib")) {
        @compileError("zux.assembler.BuildContext.make requires .lib");
    }
    if (!@hasField(Input, "assembler_config")) {
        @compileError("zux.assembler.BuildContext.make requires .assembler_config");
    }
    if (!@hasField(Input, "build_config")) {
        @compileError("zux.assembler.BuildContext.make requires .build_config");
    }
    if (!@hasField(Input, "registries")) {
        @compileError("zux.assembler.BuildContext.make requires .registries");
    }
    if (!@hasField(Input, "store_builder")) {
        @compileError("zux.assembler.BuildContext.make requires .store_builder");
    }
    if (!@hasField(Input, "node_builder")) {
        @compileError("zux.assembler.BuildContext.make requires .node_builder");
    }
    if (!@hasField(Input, "channel")) {
        @compileError("zux.assembler.BuildContext.make requires .channel");
    }

    break :blk struct {
        lib: type,
        assembler_config: Config,
        build_config: @TypeOf(@field(input, "build_config")),
        registries: @TypeOf(@field(input, "registries")),
        store_builder: @TypeOf(@field(input, "store_builder")),
        node_builder: @TypeOf(@field(input, "node_builder")),
        channel: @TypeOf(@field(input, "channel")),
    };
} {
    return .{
        .lib = @field(input, "lib"),
        .assembler_config = @field(input, "assembler_config"),
        .build_config = @field(input, "build_config"),
        .registries = @field(input, "registries"),
        .store_builder = @field(input, "store_builder"),
        .node_builder = @field(input, "node_builder"),
        .channel = @field(input, "channel"),
    };
}
