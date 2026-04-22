const registry_unique = @import("unique.zig");

pub fn make(comptime max_flows: usize) type {
    return struct {
        const Self = @This();

        pub const Flow = struct {
            label: []const u8,
            id: u32,
            FlowType: type,
        };

        periphs: [max_flows]Flow = undefined,
        len: usize = 0,

        pub fn init() Self {
            return .{};
        }

        pub fn add(
            self: *Self,
            comptime label: anytype,
            comptime id: u32,
            comptime FlowType: type,
        ) void {
            if (self.len >= max_flows) {
                @compileError("zux.Assembler exceeded max_flows");
            }
            const label_name = registry_unique.labelText(label);
            registry_unique.ensureUnique(
                self.periphs,
                self.len,
                label_name,
                id,
                "zux.Assembler.addFlow duplicate label",
                "zux.Assembler.addFlow duplicate id",
            );

            self.periphs[self.len] = .{
                .label = label_name,
                .id = id,
                .FlowType = FlowType,
            };
            self.len += 1;
        }

        pub fn count(self: *const Self) usize {
            return self.len;
        }
    };
}
