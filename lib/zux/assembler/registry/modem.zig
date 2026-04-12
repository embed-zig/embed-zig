const modem_api = @import("modem");

const EnumLiteral = @Type(.enum_literal);

pub fn make(comptime max_modem: usize) type {
    return struct {
        const Self = @This();

        pub const Periph = struct {
            label: EnumLiteral,
            id: u32,
            control_type: type,
        };

        periphs: [max_modem]Periph = undefined,
        len: usize = 0,

        pub fn init() Self {
            return .{};
        }

        pub fn add(
            self: *Self,
            comptime label: EnumLiteral,
            comptime id: u32,
        ) void {
            if (self.len >= max_modem) {
                @compileError("zux.Assembler exceeded max_modem");
            }

            self.periphs[self.len] = .{
                .label = label,
                .id = id,
                .control_type = modem_api.Modem,
            };
            self.len += 1;
        }

        pub fn count(self: *const Self) usize {
            return self.len;
        }
    };
}
