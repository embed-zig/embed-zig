const display_error = @import("Error.zig");
const DrawArgs = @import("DrawArgs.zig");
const Comparer = @import("Comparer.zig");

/// Runs each comparer in order on the same [`DrawArgs`]; all must return `true`.
/// Any error from a step propagates; first `false` short-circuits.
steps: []const Comparer,

pub fn init(steps: []const Comparer) @This() {
    return .{ .steps = steps };
}

pub fn comparer(self: *@This()) Comparer {
    return Comparer.from(@This(), self);
}

pub fn check(self: *@This(), draw: DrawArgs) display_error.Error!bool {
    for (self.steps) |step| {
        const ok = try Comparer.check(&step, draw);
        if (!ok) return false;
    }
    return true;
}
