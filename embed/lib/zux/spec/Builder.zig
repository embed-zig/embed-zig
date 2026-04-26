const Spec = @import("../Spec.zig");
const Doc = @import("Doc.zig");

const Builder = @This();

doc: Doc = .{},

pub fn init() Builder {
    return .{};
}

pub fn addSpecSlice(self: *Builder, comptime source: []const u8) void {
    const parsed = comptime Spec.parseSlice(source);
    self.doc.addParsed(parsed);
}

pub fn addSpecSlices(self: *Builder, comptime sources: []const []const u8) void {
    for (sources) |source| {
        self.addSpecSlice(source);
    }
}

pub fn build(self: *const Builder) type {
    return Spec.make(self.doc);
}
