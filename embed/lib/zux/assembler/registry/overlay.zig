const registry_unique = @import("unique.zig");

pub fn make(comptime max_overlays: usize) type {
    return struct {
        const Self = @This();

        pub const Overlay = struct {
            label: []const u8,
            id: u32,
        };

        periphs: [max_overlays]Overlay = undefined,
        len: usize = 0,

        pub fn init() Self {
            return .{};
        }

        pub fn add(
            self: *Self,
            comptime label: anytype,
            comptime id: u32,
        ) void {
            if (self.len >= max_overlays) {
                @compileError("zux.Assembler exceeded max_overlays");
            }
            const label_name = registry_unique.labelText(label);
            registry_unique.ensureUnique(
                self.periphs,
                self.len,
                label_name,
                id,
                "zux.Assembler.addOverlay duplicate label",
                "zux.Assembler.addOverlay duplicate id",
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
