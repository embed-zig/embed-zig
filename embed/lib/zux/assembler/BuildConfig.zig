const glib = @import("glib");
const bt = @import("bt");
const drivers = @import("drivers");
const nfc_api = @import("nfc");
const ledstrip = @import("ledstrip");
const modem_api = @import("drivers");

pub fn make(comptime config: anytype) type {
    @setEvalBranchQuota(10_000);
    const info = configStructInfo(config);
    const total_len = totalPeriphLen(config);
    var fields: [total_len]glib.std.builtin.Type.StructField = undefined;
    comptime var field_index: usize = 0;

    inline for (info.fields) |field| {
        const registry = @field(config, field.name);
        inline for (0..registryPeriphLen(registry)) |i| {
            const periph = registry.periphs[i];
            if (!periphRequiresBuildConfig(periph)) continue;
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
    @setEvalBranchQuota(10_000);
    const info = configStructInfo(config);
    var out: make(config) = undefined;

    inline for (info.fields) |field| {
        const registry = @field(config, field.name);
        inline for (0..registryPeriphLen(registry)) |i| {
            const periph = registry.periphs[i];
            if (!periphRequiresBuildConfig(periph)) continue;
            @field(out, periphLabel(periph)) = periphBuildType(periph);
        }
    }

    return out;
}

fn configStructInfo(comptime config: anytype) glib.std.builtin.Type.Struct {
    const ConfigType = @TypeOf(config);
    return switch (@typeInfo(ConfigType)) {
        .@"struct" => |info| info,
        else => @compileError("zux.assembler.BuildConfig.make requires a struct config"),
    };
}

fn totalPeriphLen(comptime config: anytype) usize {
    @setEvalBranchQuota(10_000);
    const info = configStructInfo(config);
    comptime var total: usize = 0;

    inline for (info.fields) |field| {
        const registry = @field(config, field.name);
        inline for (0..registryPeriphLen(registry)) |i| {
            if (periphRequiresBuildConfig(registry.periphs[i])) {
                total += 1;
            }
        }
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
    if (ControlType == type) return type;
    if (ControlType == bt.Host) return bt.Host;
    if (ControlType == drivers.Display) return drivers.Display;
    if (ControlType == drivers.Gpio) return drivers.Gpio;
    if (ControlType == drivers.button.Single) return drivers.button.Single;
    if (ControlType == drivers.button.Grouped) return drivers.button.Grouped;
    if (ControlType == drivers.imu) return drivers.imu;
    if (ControlType == modem_api.Modem) return modem_api.Modem;
    if (ControlType == nfc_api.Reader) return nfc_api.Reader;
    if (ControlType == drivers.Switch) return drivers.Switch;
    if (ControlType == drivers.Pwm) return drivers.Pwm;
    if (ControlType == drivers.Touch) return drivers.Touch;
    if (ControlType == drivers.wifi.Sta) return drivers.wifi.Sta;
    if (ControlType == drivers.wifi.Ap) return drivers.wifi.Ap;
    if (ControlType == ledstrip.LedStrip) return ledstrip.LedStrip;
    @compileError("zux.assembler.BuildConfig.make encountered unsupported periph control_type");
}

fn periphRequiresBuildConfig(comptime periph: anytype) bool {
    const PeriphType = @TypeOf(periph);
    if (@hasField(PeriphType, "input_type") and @field(periph, "input_type") == .virtual) {
        return false;
    }
    return true;
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
