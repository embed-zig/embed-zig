const route = @import("../../component/ui/route.zig");
const registry_unique = @import("unique.zig");

const EnumLiteral = @Type(.enum_literal);

pub fn make(comptime max_routers: usize) type {
    return struct {
        const Self = @This();

        pub const Router = struct {
            label: EnumLiteral,
            id: u32,
            initial_item: route.Router.Item,
        };

        periphs: [max_routers]Router = undefined,
        len: usize = 0,

        pub fn init() Self {
            return .{};
        }

        pub fn add(
            self: *Self,
            comptime label: EnumLiteral,
            comptime id: u32,
            comptime initial_item: route.Router.Item,
        ) void {
            if (self.len >= max_routers) {
                @compileError("zux.Assembler exceeded max_routers");
            }
            registry_unique.ensureUnique(
                self.periphs,
                self.len,
                label,
                id,
                "zux.Assembler.addRouter duplicate label",
                "zux.Assembler.addRouter duplicate id",
            );

            self.periphs[self.len] = .{
                .label = label,
                .id = id,
                .initial_item = initial_item,
            };
            self.len += 1;
        }

        pub fn count(self: *const Self) usize {
            return self.len;
        }
    };
}
