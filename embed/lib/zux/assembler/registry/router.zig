const registry_unique = @import("unique.zig");

pub fn make(comptime max_routers: usize) type {
    return struct {
        const Self = @This();

        pub const Router = struct {
            label: []const u8,
            id: u32,
        };

        periphs: [max_routers]Router = undefined,
        len: usize = 0,

        pub fn init() Self {
            return .{};
        }

        pub fn add(
            self: *Self,
            comptime label: anytype,
            comptime id: u32,
        ) void {
            if (self.len >= max_routers) {
                @compileError("zux.Assembler exceeded max_routers");
            }
            const label_name = registry_unique.labelText(label);
            registry_unique.ensureUnique(
                self.periphs,
                self.len,
                label_name,
                id,
                "zux.Assembler.addRouter duplicate label",
                "zux.Assembler.addRouter duplicate id",
            );

            self.periphs[self.len] = .{
                .label = label_name,
                .id = id,
            };
            self.len += 1;
        }

        pub fn count(self: *const Self) usize {
            return self.len;
        }
    };
}
