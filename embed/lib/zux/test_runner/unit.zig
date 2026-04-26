const glib = @import("glib");
const builtin = @import("builtin");
const Component = @import("../spec/Component.zig");
const JsonParser = @import("../spec/JsonParser.zig");
const Spec = @import("../Spec.zig");
const UserStory = @import("../spec/UserStory.zig");

pub const assembler = @import("unit/assembler.zig");
pub const button = @import("unit/button.zig");
pub const bt = @import("unit/bt.zig");
pub const event = @import("unit/event.zig");
pub const imu = @import("unit/imu.zig");
pub const modem = @import("unit/modem.zig");
pub const netstack = @import("unit/netstack.zig");
pub const nfc = @import("unit/nfc.zig");
pub const pipeline = @import("unit/pipeline.zig");
pub const store = @import("unit/store.zig");
pub const ui = @import("unit/ui.zig");
pub const wifi = @import("unit/wifi.zig");

pub fn make(comptime grt: type) glib.testing.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            if (builtin.target.os.tag == .freestanding) {
                return true;
            }

            t.parallel();
            t.run("assembler", assembler.make(grt));
            t.run("Spec", Spec.TestRunner(grt));
            t.run("spec/JsonParser", JsonParser.TestRunner(grt));
            t.run("spec/Component", Component.TestRunner(grt));
            t.run("spec/UserStory", UserStory.TestRunner(grt));
            t.run("button", button.make(grt));
            t.run("bt", bt.make(grt));
            t.run("event", event.make(grt));
            t.run("imu", imu.make(grt));
            t.run("modem", modem.make(grt));
            t.run("netstack", netstack.make(grt));
            t.run("nfc", nfc.make(grt));
            t.run("pipeline", pipeline.make(grt));
            t.run("store", store.make(grt));
            t.run("ui", ui.make(grt));
            t.run("wifi", wifi.make(grt));
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
