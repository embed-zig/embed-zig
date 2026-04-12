const drivers = @import("drivers");
const registry_unique = @import("unique.zig");

const EnumLiteral = @Type(.enum_literal);

pub fn make(comptime max_wifi_sta: usize) type {
    return struct {
        const Self = @This();

        pub const Periph = struct {
            label: EnumLiteral,
            id: u32,
            control_type: type,
        };

        periphs: [max_wifi_sta]Periph = undefined,
        len: usize = 0,

        pub fn init() Self {
            return .{};
        }

        pub fn add(
            self: *Self,
            comptime label: EnumLiteral,
            comptime id: u32,
        ) void {
            if (self.len >= max_wifi_sta) {
                @compileError("zux.Assembler exceeded max_wifi_sta");
            }
            registry_unique.ensureUnique(
                self.periphs,
                self.len,
                label,
                id,
                "zux.Assembler.addWifiSta duplicate label",
                "zux.Assembler.addWifiSta duplicate id",
            );

            self.periphs[self.len] = .{
                .label = label,
                .id = id,
                .control_type = drivers.wifi.Sta,
            };
            self.len += 1;
        }

        pub fn count(self: *const Self) usize {
            return self.len;
        }
    };
}
