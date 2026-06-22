const drivers = @import("drivers");
const Metadata = @import("../../Metadata.zig");
const registry_unique = @import("unique.zig");

pub const InputType = enum {
    poll,
    virtual,
};

pub fn make(comptime max_adc_buttons: usize) type {
    return struct {
        const Self = @This();

        pub const Periph = struct {
            label: []const u8,
            id: u32,
            metadata: Metadata,
            button_count: usize,
            control_type: type,
            input_type: InputType,
        };

        periphs: [max_adc_buttons]Periph = undefined,
        len: usize = 0,

        pub fn init() Self {
            return .{};
        }

        pub fn add(
            self: *Self,
            comptime label: anytype,
            comptime id: u32,
            comptime button_count: usize,
        ) void {
            self.addWithMetadata(label, id, Metadata.empty, button_count);
        }

        pub fn addWithMetadata(
            self: *Self,
            comptime label: anytype,
            comptime id: u32,
            comptime metadata: Metadata,
            comptime button_count: usize,
        ) void {
            self.addWithInputType(label, id, metadata, button_count, .poll);
        }

        pub fn addVirtual(
            self: *Self,
            comptime label: anytype,
            comptime id: u32,
            comptime button_count: usize,
        ) void {
            self.addVirtualWithMetadata(label, id, Metadata.empty, button_count);
        }

        pub fn addVirtualWithMetadata(
            self: *Self,
            comptime label: anytype,
            comptime id: u32,
            comptime metadata: Metadata,
            comptime button_count: usize,
        ) void {
            self.addWithInputType(label, id, metadata, button_count, .virtual);
        }

        fn addWithInputType(
            self: *Self,
            comptime label: anytype,
            comptime id: u32,
            comptime metadata: Metadata,
            comptime button_count: usize,
            comptime input_type: InputType,
        ) void {
            _ = drivers.button.AdcButton.Builder(.{
                .button_count = button_count,
            });

            if (self.len >= max_adc_buttons) {
                @compileError("zux.Assembler exceeded max_adc_buttons");
            }
            const label_name = registry_unique.labelText(label);
            registry_unique.ensureUnique(
                self.periphs,
                self.len,
                label_name,
                id,
                "zux.Assembler.addGroupedButton duplicate label",
                "zux.Assembler.addGroupedButton duplicate id",
            );

            self.periphs[self.len] = .{
                .label = label_name,
                .id = id,
                .metadata = metadata,
                .button_count = button_count,
                .control_type = drivers.button.Grouped,
                .input_type = input_type,
            };
            self.len += 1;
        }

        pub fn count(self: *const Self) usize {
            return self.len;
        }
    };
}
