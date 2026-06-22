const drivers = @import("drivers");
const Metadata = @import("../../Metadata.zig");
const registry_unique = @import("unique.zig");

pub fn make(comptime max_displays: usize) type {
    return struct {
        const Self = @This();

        pub const Periph = struct {
            label: []const u8,
            id: u32,
            metadata: Metadata,
            width: u16,
            height: u16,
            control_type: type,
        };

        periphs: [max_displays]Periph = undefined,
        len: usize = 0,

        pub fn init() Self {
            return .{};
        }

        pub fn add(
            self: *Self,
            comptime label: anytype,
            comptime id: u32,
        ) void {
            self.addWithMetadata(label, id, Metadata.empty);
        }

        pub fn addWithMetadata(
            self: *Self,
            comptime label: anytype,
            comptime id: u32,
            comptime metadata: Metadata,
        ) void {
            self.addWithMetadataAndSize(label, id, metadata, 320, 240);
        }

        pub fn addWithMetadataAndSize(
            self: *Self,
            comptime label: anytype,
            comptime id: u32,
            comptime metadata: Metadata,
            comptime width: u16,
            comptime height: u16,
        ) void {
            if (self.len >= max_displays) {
                @compileError("zux.Assembler exceeded max_displays");
            }
            if (width == 0 or height == 0) {
                @compileError("zux.Assembler.addDisplay width and height must be > 0");
            }
            const label_name = registry_unique.labelText(label);
            registry_unique.ensureUnique(
                self.periphs,
                self.len,
                label_name,
                id,
                "zux.Assembler.addDisplay duplicate label",
                "zux.Assembler.addDisplay duplicate id",
            );

            self.periphs[self.len] = .{
                .label = label_name,
                .id = id,
                .metadata = metadata,
                .width = width,
                .height = height,
                .control_type = drivers.Display,
            };
            self.len += 1;
        }

        pub fn count(self: *const Self) usize {
            return self.len;
        }
    };
}
