const ledstrip = @import("ledstrip");
const registry_unique = @import("unique.zig");

pub fn make(comptime max_led_strips: usize) type {
    return struct {
        const Self = @This();

        pub const Periph = struct {
            label: []const u8,
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
            comptime label: anytype,
            comptime id: u32,
            comptime pixel_count: usize,
        ) void {
            if (pixel_count == 0) {
                @compileError("zux.Assembler.addLedStrip pixel_count must be > 0");
            }
            if (self.len >= max_led_strips) {
                @compileError("zux.Assembler exceeded max_led_strips");
            }
            const label_name = registry_unique.labelText(label);
            registry_unique.ensureUnique(
                self.periphs,
                self.len,
                label_name,
                id,
                "zux.Assembler.addLedStrip duplicate label",
                "zux.Assembler.addLedStrip duplicate id",
            );

            self.periphs[self.len] = .{
                .label = label_name,
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
