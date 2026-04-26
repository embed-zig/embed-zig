const flow_event = @import("event.zig");

pub fn make(comptime NodeLabel: type, comptime EdgeLabel: type, comptime initial_node: NodeLabel) type {
    return struct {
        const State = @This();

        pub const Negative = struct {
            direction: flow_event.Direction,
            edge: EdgeLabel,
        };

        node: NodeLabel = initial_node,
        negative: ?Negative = null,

        pub fn clearNegative(self: *State) bool {
            if (self.negative == null) return false;
            self.negative = null;
            return true;
        }

        pub fn setNegative(self: *State, direction: flow_event.Direction, edge: EdgeLabel) bool {
            const next: Negative = .{
                .direction = direction,
                .edge = edge,
            };

            if (negativeMatches(self.negative, next)) return false;
            self.negative = next;
            return true;
        }

        pub fn negativeEql(a: ?Negative, b: ?Negative) bool {
            if (a == null and b == null) return true;
            if (a == null or b == null) return false;
            return negativeMatches(a, b.?);
        }

        fn negativeMatches(maybe_negative: ?Negative, next: Negative) bool {
            if (maybe_negative == null) return false;

            const existing = maybe_negative.?;
            return existing.direction == next.direction and
                existing.edge == next.edge;
        }
    };
}
