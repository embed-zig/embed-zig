const glib = @import("glib");
const display_api = @import("drivers");
const TestingDisplay = @import("TestingDisplay.zig");

const Display = display_api.Display;

pub fn make(
    comptime grt: type,
    comptime Case: type,
    case_data: Case,
    output: ?*Display,
) glib.testing.TestRunner {
    const Runner = struct {
        case_data: Case,
        output: ?*Display,
        td: TestingDisplay = undefined,
        display: Display = undefined,
        is_initialized: bool = false,

        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            const width_px = Case.width_px;
            const height_px = Case.height_px;

            if (self.output) |output_display| {
                if (output_display.width() < width_px or output_display.height() < height_px) {
                    return error.DisplayTooSmall;
                }
            }

            self.td = TestingDisplay.init(allocator, width_px, height_px, self.output);
            errdefer self.td.deinit();

            try self.case_data.setup(&self.td);
            self.display = try self.td.display();
            self.is_initialized = true;
        }

        pub fn run(self: *@This(), child_t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            var runner = self.case_data.makeRunner(grt, &self.display);
            defer runner.deinit(allocator);

            if (!runner.run(child_t, allocator)) {
                if (self.td.pendingFailure()) |err| {
                    child_t.logFatal(@errorName(err));
                }
                return false;
            }

            self.td.assertComplete() catch |err| {
                child_t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: glib.std.mem.Allocator) void {
            _ = allocator;
            if (self.is_initialized) {
                self.display.deinit();
                self.td.deinit();
            }
            grt.std.testing.allocator.destroy(self);
        }
    };

    const runner = grt.std.testing.allocator.create(Runner) catch @panic("OOM");
    runner.* = .{
        .case_data = case_data,
        .output = output,
    };
    return glib.testing.TestRunner.make(Runner).new(runner);
}
