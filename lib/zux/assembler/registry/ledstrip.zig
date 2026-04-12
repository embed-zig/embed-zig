const ledstrip = @import("ledstrip");
const registry_unique = @import("unique.zig");

const EnumLiteral = @Type(.enum_literal);

pub fn make(comptime max_led_strips: usize) type {
    return struct {
        const Self = @This();

        pub const Periph = struct {
            label: EnumLiteral,
            id: u32,
            pixel_count: usize,
            control_type: type,
        };

        periphs: [max_led_strips]Periph = undefined,
        len: usize = 0,

        pub fn init() Self {
            return .{};
        }

        pub fn add(
            self: *Self,
            comptime label: EnumLiteral,
            comptime id: u32,
            comptime pixel_count: usize,
        ) void {
            if (pixel_count == 0) {
                @compileError("zux.Assembler.addLedStrip pixel_count must be > 0");
            }
            if (self.len >= max_led_strips) {
                @compileError("zux.Assembler exceeded max_led_strips");
            }
            registry_unique.ensureUnique(
                self.periphs,
                self.len,
                label,
                id,
                "zux.Assembler.addLedStrip duplicate label",
                "zux.Assembler.addLedStrip duplicate id",
            );

            self.periphs[self.len] = .{
                .label = label,
                .id = id,
                .pixel_count = pixel_count,
                .control_type = ledstrip.LedStrip,
            };
            self.len += 1;
        }

        pub fn count(self: *const Self) usize {
            return self.len;
        }
    };
}
