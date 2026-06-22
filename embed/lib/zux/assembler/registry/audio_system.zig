const Metadata = @import("../../Metadata.zig");
const registry_unique = @import("unique.zig");

pub fn make(comptime max_audio_systems: usize) type {
    return struct {
        const Self = @This();

        pub const Periph = struct {
            label: []const u8,
            id: u32,
            metadata: Metadata,
            control_type: type,
        };

        periphs: [max_audio_systems]Periph = undefined,
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
            if (self.len >= max_audio_systems) {
                @compileError("zux.Assembler exceeded max_audio_systems");
            }
            const label_name = registry_unique.labelText(label);
            registry_unique.ensureUnique(
                self.periphs,
                self.len,
                label_name,
                id,
                "zux.Assembler.addAudioSystem duplicate label",
                "zux.Assembler.addAudioSystem duplicate id",
            );

            self.periphs[self.len] = .{
                .label = label_name,
                .id = id,
                .metadata = metadata,
                .control_type = type,
            };
            self.len += 1;
        }

        pub fn count(self: *const Self) usize {
            return self.len;
        }
    };
}
