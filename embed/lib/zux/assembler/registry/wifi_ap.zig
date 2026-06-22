const drivers = @import("drivers");
const Metadata = @import("../../Metadata.zig");
const registry_unique = @import("unique.zig");

pub fn make(comptime max_wifi_ap: usize) type {
    return struct {
        const Self = @This();

        pub const Periph = struct {
            label: []const u8,
            id: u32,
            metadata: Metadata,
            control_type: type,
        };

        periphs: [max_wifi_ap]Periph = undefined,
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
            if (self.len >= max_wifi_ap) {
                @compileError("zux.Assembler exceeded max_wifi_ap");
            }
            const label_name = registry_unique.labelText(label);
            registry_unique.ensureUnique(
                self.periphs,
                self.len,
                label_name,
                id,
                "zux.Assembler.addWifiAp duplicate label",
                "zux.Assembler.addWifiAp duplicate id",
            );

            self.periphs[self.len] = .{
                .label = label_name,
                .id = id,
                .metadata = metadata,
                .control_type = drivers.wifi.Ap,
            };
            self.len += 1;
        }

        pub fn count(self: *const Self) usize {
            return self.len;
        }
    };
}
