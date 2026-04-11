const drivers = @import("drivers");

const EnumLiteral = @Type(.enum_literal);

pub fn make(comptime max_adc_buttons: usize) type {
    return struct {
        const Self = @This();

        pub const Periph = struct {
            label: EnumLiteral,
            id: u32,
            button_count: usize,
            control_type: type,
        };

        periphs: [max_adc_buttons]Periph = undefined,
        len: usize = 0,

        pub fn init() Self {
            return .{};
        }

        pub fn add(
            self: *Self,
            comptime label: EnumLiteral,
            comptime id: u32,
            comptime button_count: usize,
        ) void {
            _ = drivers.button.AdcButton.Builder(.{
                .button_count = button_count,
            });

            if (self.len >= max_adc_buttons) {
                @compileError("zux.Assembler exceeded max_adc_buttons");
            }

            self.periphs[self.len] = .{
                .label = label,
                .id = id,
                .button_count = button_count,
                .control_type = drivers.button.Grouped,
            };
            self.len += 1;
        }

        pub fn count(self: *const Self) usize {
            return self.len;
        }
    };
}
