const embed = @import("embed");
const builtin = embed.builtin;
const drivers = @import("drivers");
const ledstrip = @import("ledstrip");

pub fn make(comptime config: anytype) type {
    const info = configStructInfo(config);
    const total_len = totalPeriphLen(config);
    var fields: [total_len]builtin.Type.StructField = undefined;
    comptime var field_index: usize = 0;

    inline for (info.fields) |field| {
        const registry = @field(config, field.name);
        inline for (0..registryPeriphLen(registry)) |i| {
            const periph = registry.periphs[i];
            fields[field_index] = .{
                .name = sentinelName(periphLabel(periph)),
                .type = type,
                .default_value_ptr = null,
                .is_comptime = false,
                .alignment = @alignOf(type),
            };
            field_index += 1;
        }
    }

    return @Type(.{
        .@"struct" = .{
            .layout = .auto,
            .fields = &fields,
            .decls = &.{},
            .is_tuple = false,
        },
    });
}

pub fn build(comptime config: anytype) make(config) {
    const info = configStructInfo(config);
    var out: make(config) = undefined;

    inline for (info.fields) |field| {
        const registry = @field(config, field.name);
        inline for (0..registryPeriphLen(registry)) |i| {
            const periph = registry.periphs[i];
            @field(out, periphLabel(periph)) = periphBuildType(periph);
        }
    }

    return out;
}

fn configStructInfo(comptime config: anytype) builtin.Type.Struct {
    const ConfigType = @TypeOf(config);
    return switch (@typeInfo(ConfigType)) {
        .@"struct" => |info| info,
        else => @compileError("zux.assembler.BuildConfig.make requires a struct config"),
    };
}

fn totalPeriphLen(comptime config: anytype) usize {
    const info = configStructInfo(config);
    comptime var total: usize = 0;

    inline for (info.fields) |field| {
        total += registryPeriphLen(@field(config, field.name));
    }

    return total;
}

fn registryPeriphLen(comptime registry: anytype) usize {
    const RegistryType = @TypeOf(registry);
    if (!@hasField(RegistryType, "periphs") or !@hasField(RegistryType, "len")) {
        @compileError("zux.assembler.BuildConfig.make requires registry fields `periphs` and `len`");
    }
    return registry.len;
}

fn periphLabel(comptime periph: anytype) []const u8 {
    const PeriphType = @TypeOf(periph);
    if (@hasField(PeriphType, "label")) {
        return labelText(@field(periph, "label"));
    }
    if (@hasDecl(PeriphType, "label")) {
        return labelText(periph.label());
    }
    @compileError("zux.assembler.BuildConfig.make periph must expose `label`");
}

fn periphBuildType(comptime periph: anytype) type {
    const PeriphType = @TypeOf(periph);
    if (!@hasField(PeriphType, "control_type")) {
        @compileError("zux.assembler.BuildConfig.make periph must expose `control_type`");
    }
    const ControlType = @field(periph, "control_type");
    if (ControlType == drivers.button.Single) return drivers.button.Single;
    if (ControlType == drivers.button.Grouped) return drivers.button.Grouped;
    if (ControlType == ledstrip.LedStrip) return ledstrip.LedStrip;
    @compileError("zux.assembler.BuildConfig.make encountered unsupported periph control_type");
}

fn labelText(comptime raw_label: anytype) []const u8 {
    return switch (@typeInfo(@TypeOf(raw_label))) {
        .enum_literal => @tagName(raw_label),
        .pointer => |ptr| switch (ptr.size) {
            .slice => raw_label,
            .one => switch (@typeInfo(ptr.child)) {
                .array => raw_label[0..],
                else => @compileError("zux.assembler.BuildConfig.make label must be enum_literal or []const u8"),
            },
            else => @compileError("zux.assembler.BuildConfig.make label must be enum_literal or []const u8"),
        },
        .array => raw_label[0..],
        else => @compileError("zux.assembler.BuildConfig.make label must be enum_literal or []const u8"),
    };
}

fn sentinelName(comptime text: []const u8) [:0]const u8 {
    const terminated = text ++ "\x00";
    return terminated[0..text.len :0];
}
