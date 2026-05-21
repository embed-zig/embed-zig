const Config = @import("Config.zig");

pub fn make(comptime input: anytype) blk: {
    const Input = @TypeOf(input);

    if (!@hasField(Input, "grt")) {
        @compileError("zux.assembler.BuildContext.make requires .grt");
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
    if (!@hasField(Input, "render_bindings")) {
        @compileError("zux.assembler.BuildContext.make requires .render_bindings");
    }
    if (!@hasField(Input, "render_count")) {
        @compileError("zux.assembler.BuildContext.make requires .render_count");
    }
    if (!@hasField(Input, "reducer_bindings")) {
        @compileError("zux.assembler.BuildContext.make requires .reducer_bindings");
    }
    if (!@hasField(Input, "reducer_count")) {
        @compileError("zux.assembler.BuildContext.make requires .reducer_count");
    }
    if (!@hasField(Input, "custom_event_registar")) {
        @compileError("zux.assembler.BuildContext.make requires .custom_event_registar");
    }
    break :blk struct {
        grt: type,
        assembler_config: Config,
        build_config: @TypeOf(@field(input, "build_config")),
        registries: @TypeOf(@field(input, "registries")),
        store_builder: @TypeOf(@field(input, "store_builder")),
        render_bindings: @TypeOf(@field(input, "render_bindings")),
        render_count: @TypeOf(@field(input, "render_count")),
        reducer_bindings: @TypeOf(@field(input, "reducer_bindings")),
        reducer_count: @TypeOf(@field(input, "reducer_count")),
        custom_event_registar: @TypeOf(@field(input, "custom_event_registar")),
    };
} {
    return .{
        .grt = @field(input, "grt"),
        .assembler_config = @field(input, "assembler_config"),
        .build_config = @field(input, "build_config"),
        .registries = @field(input, "registries"),
        .store_builder = @field(input, "store_builder"),
        .render_bindings = @field(input, "render_bindings"),
        .render_count = @field(input, "render_count"),
        .reducer_bindings = @field(input, "reducer_bindings"),
        .reducer_count = @field(input, "reducer_count"),
        .custom_event_registar = @field(input, "custom_event_registar"),
    };
}
