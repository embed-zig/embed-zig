const glib = @import("glib");

const Message = @import("../../pipeline/Message.zig");
const Emitter = @import("../../pipeline/Emitter.zig");
const Node = @import("../../pipeline/Node.zig");
const Poller = @import("../../pipeline/Poller.zig");
const NodeBuilder = @import("../../pipeline/NodeBuilder.zig");
const BranchNode = @import("../../pipeline/BranchNode.zig");
const Pipeline = @import("../../pipeline/Pipeline.zig");

pub fn make(comptime grt: type) glib.testing.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;
            _ = allocator;
            t.parallel();
            t.run("Message", Message.TestRunner(grt));
            t.run("Emitter", Emitter.TestRunner(grt));
            t.run("Node", Node.TestRunner(grt));
            t.run("Poller", Poller.TestRunner(grt));
            t.run("NodeBuilder", NodeBuilder.TestRunner(grt));
            t.run("BranchNode", BranchNode.TestRunner(grt));
            t.run("Pipeline", Pipeline.TestRunner(grt));
            return t.wait();
        }

        pub fn deinit(self: *@This(), allocator: glib.std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return glib.testing.TestRunner.make(Runner).new(&Holder.runner);
}
