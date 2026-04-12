const drivers = @import("drivers");
const registry_unique = @import("unique.zig");

const EnumLiteral = @Type(.enum_literal);

pub fn make(comptime max_imu: usize) type {
    return struct {
        const Self = @This();

        pub const Periph = struct {
            label: EnumLiteral,
            id: u32,
            control_type: type,
        };

        periphs: [max_imu]Periph = undefined,
        len: usize = 0,

        pub fn init() Self {
            return .{};
        }

        pub fn add(
            self: *Self,
            comptime label: EnumLiteral,
            comptime id: u32,
        ) void {
            if (self.len >= max_imu) {
                @compileError("zux.Assembler exceeded max_imu");
            }
            registry_unique.ensureUnique(
                self.periphs,
                self.len,
                label,
                id,
                "zux.Assembler.addImu duplicate label",
                "zux.Assembler.addImu duplicate id",
            );

            self.periphs[self.len] = .{
                .label = label,
                .id = id,
                .control_type = drivers.imu,
            };
            self.len += 1;
        }

        pub fn count(self: *const Self) usize {
            return self.len;
        }
    };
}
