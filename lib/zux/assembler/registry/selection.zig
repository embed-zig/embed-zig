const selection = @import("../../component/ui/selection.zig");
const registry_unique = @import("unique.zig");

const EnumLiteral = @Type(.enum_literal);

pub fn make(comptime max_selections: usize) type {
    return struct {
        const Self = @This();

        pub const Selection = struct {
            label: EnumLiteral,
            id: u32,
            initial_state: selection.State,
        };

        periphs: [max_selections]Selection = undefined,
        len: usize = 0,

        pub fn init() Self {
            return .{};
        }

        pub fn add(
            self: *Self,
            comptime label: EnumLiteral,
            comptime id: u32,
            comptime initial_state: selection.State,
        ) void {
            if (self.len >= max_selections) {
                @compileError("zux.Assembler exceeded max_selections");
            }
            registry_unique.ensureUnique(
                self.periphs,
                self.len,
                label,
                id,
                "zux.Assembler.addSelection duplicate label",
                "zux.Assembler.addSelection duplicate id",
            );

            self.periphs[self.len] = .{
                .label = label,
                .id = id,
                .initial_state = initial_state,
            };
            self.len += 1;
        }

        pub fn count(self: *const Self) usize {
            return self.len;
        }
    };
}
