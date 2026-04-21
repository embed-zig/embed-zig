const drivers = @import("drivers");
const registry_unique = @import("unique.zig");

pub fn make(comptime max_nfc: usize) type {
    return struct {
        const Self = @This();

        pub const Periph = struct {
            label: []const u8,
            id: u32,
            control_type: type,
        };

        periphs: [max_nfc]Periph = undefined,
        len: usize = 0,

        pub fn init() Self {
            return .{};
        }

        pub fn add(
            self: *Self,
            comptime label: anytype,
            comptime id: u32,
        ) void {
            if (self.len >= max_nfc) {
                @compileError("zux.Assembler exceeded max_nfc");
            }
            const label_name = registry_unique.labelText(label);
            registry_unique.ensureUnique(
                self.periphs,
                self.len,
                label_name,
                id,
                "zux.Assembler.addNfc duplicate label",
                "zux.Assembler.addNfc duplicate id",
            );

            self.periphs[self.len] = .{
                .label = label_name,
                .id = id,
                .control_type = drivers.nfc.Reader,
            };
            self.len += 1;
        }

        pub fn count(self: *const Self) usize {
            return self.len;
        }
    };
}
