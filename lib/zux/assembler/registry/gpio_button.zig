const drivers = @import("drivers");
const registry_unique = @import("unique.zig");

pub fn make(comptime max_gpio_buttons: usize) type {
    return struct {
        const Self = @This();

        pub const Periph = struct {
            label: []const u8,
            id: u32,
            control_type: type,
        };

        periphs: [max_gpio_buttons]Periph = undefined,
        len: usize = 0,

        pub fn init() Self {
            return .{};
        }

        pub fn add(
            self: *Self,
            comptime label: anytype,
            comptime id: u32,
        ) void {
            if (self.len >= max_gpio_buttons) {
                @compileError("zux.Assembler exceeded max_gpio_buttons");
            }
            const label_name = registry_unique.labelText(label);
            registry_unique.ensureUnique(
                self.periphs,
                self.len,
                label_name,
                id,
                "zux.Assembler.addSingleButton duplicate label",
                "zux.Assembler.addSingleButton duplicate id",
            );

            self.periphs[self.len] = .{
                .label = label_name,
                .id = id,
                .control_type = drivers.button.Single,
            };
            self.len += 1;
        }

        pub fn count(self: *const Self) usize {
            return self.len;
        }
    };
}
