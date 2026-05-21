const drivers = @import("drivers");
const registry_unique = @import("unique.zig");

pub fn make(comptime max_touch: usize) type {
    return struct {
        const Self = @This();

        pub const Periph = struct {
            label: []const u8,
            id: u32,
            control_type: type,
            target: ?[]const u8,
        };

        periphs: [max_touch]Periph = undefined,
        len: usize = 0,

        pub fn init() Self {
            return .{};
        }

        pub fn add(
            self: *Self,
            comptime label: anytype,
            comptime id: u32,
            comptime target: ?[]const u8,
        ) void {
            if (self.len >= max_touch) {
                @compileError("zux.Assembler exceeded max_touch");
            }
            const label_name = registry_unique.labelText(label);
            registry_unique.ensureUnique(
                self.periphs,
                self.len,
                label_name,
                id,
                "zux.Assembler.addTouch duplicate label",
                "zux.Assembler.addTouch duplicate id",
            );

            self.periphs[self.len] = .{
                .label = label_name,
                .id = id,
                .control_type = drivers.Touch,
                .target = target,
            };
            self.len += 1;
        }

        pub fn count(self: *const Self) usize {
            return self.len;
        }
    };
}
