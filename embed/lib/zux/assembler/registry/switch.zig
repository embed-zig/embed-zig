const drivers = @import("drivers");
const Metadata = @import("../../Metadata.zig");
const registry_unique = @import("unique.zig");

pub fn makeSwitch(comptime max_switches: usize) type {
    return make(max_switches, drivers.Switch, "switch");
}

pub fn makePwm(comptime max_pwms: usize) type {
    return make(max_pwms, drivers.Pwm, "pwm");
}

fn make(comptime max_outputs: usize, comptime control_type: type, comptime name: []const u8) type {
    return struct {
        const Self = @This();

        pub const Periph = struct {
            label: []const u8,
            id: u32,
            metadata: Metadata,
            control_type: type,
        };

        periphs: [max_outputs]Periph = undefined,
        len: usize = 0,

        pub fn init() Self {
            return .{};
        }

        pub fn add(
            self: *Self,
            comptime label: anytype,
            comptime id: u32,
        ) void {
            self.addWithMetadata(label, id, Metadata.empty);
        }

        pub fn addWithMetadata(
            self: *Self,
            comptime label: anytype,
            comptime id: u32,
            comptime metadata: Metadata,
        ) void {
            if (self.len >= max_outputs) {
                @compileError("zux.Assembler exceeded max_" ++ name ++ "s");
            }
            const label_name = registry_unique.labelText(label);
            registry_unique.ensureUnique(
                self.periphs,
                self.len,
                label_name,
                id,
                "zux.Assembler.add" ++ name ++ " duplicate label",
                "zux.Assembler.add" ++ name ++ " duplicate id",
            );

            self.periphs[self.len] = .{
                .label = label_name,
                .id = id,
                .metadata = metadata,
                .control_type = control_type,
            };
            self.len += 1;
        }

        pub fn count(self: *const Self) usize {
            return self.len;
        }
    };
}
