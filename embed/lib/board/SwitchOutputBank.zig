const drivers = @import("drivers");

pub fn make(comptime max_outputs: usize) type {
    return struct {
        const Self = @This();
        const max_label_len = 32;

        outputs: [max_outputs]Output = [_]Output{.{}} ** max_outputs,

        pub fn get(self: *Self, label: []const u8) !drivers.Switch {
            if (label.len > max_label_len) return error.LabelTooLong;

            for (&self.outputs) |*output| {
                if (output.matches(label)) return output.handle();
            }

            for (&self.outputs) |*output| {
                if (!output.claimed) {
                    output.claim(label);
                    return output.handle();
                }
            }

            return error.NoFreeSwitchOutput;
        }

        const Output = struct {
            claimed: bool = false,
            label: [max_label_len]u8 = [_]u8{0} ** max_label_len,
            label_len: usize = 0,
            enabled: bool = false,

            fn claim(self: *Output, label: []const u8) void {
                @memcpy(self.label[0..label.len], label);
                self.label_len = label.len;
                self.claimed = true;
                self.enabled = false;
            }

            fn matches(self: *Output, label: []const u8) bool {
                if (!self.claimed or self.label_len != label.len) return false;
                for (self.label[0..self.label_len], label) |a, b| {
                    if (a != b) return false;
                }
                return true;
            }

            fn handle(self: *Output) drivers.Switch {
                return drivers.Switch.init(self);
            }

            pub fn set(self: *Output, enabled: bool) drivers.Switch.Error!void {
                self.enabled = enabled;
            }

            pub fn get(self: *Output) drivers.Switch.Error!bool {
                return self.enabled;
            }
        };
    };
}
