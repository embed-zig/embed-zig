const drivers = @import("drivers");
const Metadata = @import("../../Metadata.zig");
const registry_unique = @import("unique.zig");

pub const InputType = enum {
    poll,
    virtual,
};

pub fn make(comptime max_single_buttons: usize) type {
    return struct {
        const Self = @This();

        pub const Periph = struct {
            label: []const u8,
            id: u32,
            metadata: Metadata,
            control_type: type,
            input_type: InputType,
        };

        periphs: [max_single_buttons]Periph = undefined,
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
            self.addWithInputType(label, id, metadata, .poll);
        }

        pub fn addVirtual(
            self: *Self,
            comptime label: anytype,
            comptime id: u32,
        ) void {
            self.addVirtualWithMetadata(label, id, Metadata.empty);
        }

        pub fn addVirtualWithMetadata(
            self: *Self,
            comptime label: anytype,
            comptime id: u32,
            comptime metadata: Metadata,
        ) void {
            self.addWithInputType(label, id, metadata, .virtual);
        }

        fn addWithInputType(
            self: *Self,
            comptime label: anytype,
            comptime id: u32,
            comptime metadata: Metadata,
            comptime input_type: InputType,
        ) void {
            if (self.len >= max_single_buttons) {
                @compileError("zux.Assembler exceeded max_single_buttons");
            }
            const label_name = registry_unique.labelText(label);
            registry_unique.ensureUnique(
                self.periphs,
                self.len,
                label_name,
                id,
                "zux.Assembler.addSingleButton duplicate label",
                "zux.Assembler.addSingleButton duplicate id",
            );

            self.periphs[self.len] = .{
                .label = label_name,
                .id = id,
                .metadata = metadata,
                .control_type = drivers.button.Single,
                .input_type = input_type,
            };
            self.len += 1;
        }

        pub fn count(self: *const Self) usize {
            return self.len;
        }
    };
}
