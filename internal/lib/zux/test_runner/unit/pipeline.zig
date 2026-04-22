const testing_api = @import("testing");

const Message = @import("../../pipeline/Message.zig");
const Emitter = @import("../../pipeline/Emitter.zig");
const Node = @import("../../pipeline/Node.zig");
const Poller = @import("../../pipeline/Poller.zig");
const NodeBuilder = @import("../../pipeline/NodeBuilder.zig");
const BranchNode = @import("../../pipeline/BranchNode.zig");
const Pipeline = @import("../../pipeline/Pipeline.zig");

pub fn make(comptime lib: type, comptime Channel: fn (type) type) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;
            t.parallel();
            t.run("Message", Message.TestRunner(lib));
            t.run("Emitter", Emitter.TestRunner(lib));
            t.run("Node", Node.TestRunner(lib));
            t.run("Poller", Poller.TestRunner(lib));
            t.run("NodeBuilder", NodeBuilder.TestRunner(lib));
            t.run("BranchNode", BranchNode.TestRunner(lib));
            t.run("Pipeline", Pipeline.TestRunner(lib, Channel));
            return t.wait();
        }

        pub fn deinit(self: *@This(), allocator: lib.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}
