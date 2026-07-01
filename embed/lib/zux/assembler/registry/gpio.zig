const drivers = @import("drivers");
const Metadata = @import("../../Metadata.zig");
const registry_unique = @import("unique.zig");

pub const InputType = enum {
    irq,
    poll,
    virtual,
};

pub fn make(comptime max_gpio: usize) type {
    return struct {
        const Self = @This();

        pub const Periph = struct {
            label: []const u8,
            id: u32,
            metadata: Metadata,
            control_type: type,
            input_type: InputType,
        };

        periphs: [max_gpio]Periph = undefined,
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

        pub fn addIrq(
            self: *Self,
            comptime label: anytype,
            comptime id: u32,
        ) void {
            self.addIrqWithMetadata(label, id, Metadata.empty);
        }

        pub fn addIrqWithMetadata(
            self: *Self,
            comptime label: anytype,
            comptime id: u32,
            comptime metadata: Metadata,
        ) void {
            self.addWithInputType(label, id, metadata, .irq);
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
            if (self.len >= max_gpio) {
                @compileError("zux.Assembler exceeded max_gpio");
            }
            const label_name = registry_unique.labelText(label);
            registry_unique.ensureUnique(
                self.periphs,
                self.len,
                label_name,
                id,
                "zux.Assembler.addGpio duplicate label",
                "zux.Assembler.addGpio duplicate id",
            );

            self.periphs[self.len] = .{
                .label = label_name,
                .id = id,
                .metadata = metadata,
                .control_type = drivers.Gpio,
                .input_type = input_type,
            };
            self.len += 1;
        }

        pub fn count(self: *const Self) usize {
            return self.len;
        }
    };
}
