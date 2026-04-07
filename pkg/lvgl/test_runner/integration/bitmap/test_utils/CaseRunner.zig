const display_api = @import("display");
const testing_mod = @import("testing");
const TestingDisplay = @import("TestingDisplay.zig");
const Fixture = @import("Fixture.zig");

const Display = display_api.Display;

pub fn make(comptime lib: type, comptime Case: type, case_data: Case) testing_mod.TestRunner {
    const Runner = struct {
        case_data: Case,
        td: TestingDisplay = undefined,
        display: Display = undefined,
        is_initialized: bool = false,

        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            self.td = TestingDisplay.init(allocator, Fixture.width, Fixture.height);
            errdefer self.td.deinit();

            try self.case_data.setup(&self.td);
            self.display = try self.td.display();
            self.is_initialized = true;
        }

        pub fn run(self: *@This(), child_t: *testing_mod.T, allocator: lib.mem.Allocator) bool {
            var runner = self.case_data.makeRunner(lib, &self.display);
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

        pub fn deinit(self: *@This(), allocator: lib.mem.Allocator) void {
            _ = allocator;
            if (self.is_initialized) {
                self.display.deinit();
                self.td.deinit();
            }
            lib.testing.allocator.destroy(self);
        }
    };

    const runner = lib.testing.allocator.create(Runner) catch @panic("OOM");
    runner.* = .{ .case_data = case_data };
    return testing_mod.TestRunner.make(Runner).new(runner);
}
