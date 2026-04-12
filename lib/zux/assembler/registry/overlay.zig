const overlay = @import("../../component/ui/overlay.zig");
const registry_unique = @import("unique.zig");

const EnumLiteral = @Type(.enum_literal);

pub fn make(comptime max_overlays: usize) type {
    return struct {
        const Self = @This();

        pub const Overlay = struct {
            label: EnumLiteral,
            id: u32,
            initial_state: overlay.State,
        };

        periphs: [max_overlays]Overlay = undefined,
        len: usize = 0,

        pub fn init() Self {
            return .{};
        }

        pub fn add(
            self: *Self,
            comptime label: EnumLiteral,
            comptime id: u32,
            comptime initial_state: overlay.State,
        ) void {
            if (self.len >= max_overlays) {
                @compileError("zux.Assembler exceeded max_overlays");
            }
            registry_unique.ensureUnique(
                self.periphs,
                self.len,
                label,
                id,
                "zux.Assembler.addOverlay duplicate label",
                "zux.Assembler.addOverlay duplicate id",
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
