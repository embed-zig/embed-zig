const glib = @import("glib");

const Mixer = @import("../../Mixer.zig");
const RingBuffer = @import("../../mixer/RingBuffer.zig");
const Track = @import("../../mixer/Track.zig");
const TrackCtrl = @import("../../mixer/TrackCtrl.zig");
const TrackState = @import("../../mixer/TrackState.zig");

pub fn make(comptime lib: type) glib.testing.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.parallel();
            t.run("Mixer", Mixer.TestRunner(lib));
            t.run("RingBuffer", RingBuffer.TestRunner(lib));
            t.run("Track", Track.TestRunner(lib));
            t.run("TrackCtrl", TrackCtrl.TestRunner(lib));
            t.run("TrackState", TrackState.TestRunner(lib));
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
    return glib.testing.TestRunner.make(Runner).new(&Holder.runner);
}
