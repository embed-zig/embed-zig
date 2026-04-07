//! Bitmap integration runner — aggregates per-case bitmap checks.

const embed = @import("embed");
const testing = @import("testing");
const CaseRunner = @import("bitmap/test_utils/CaseRunner.zig");
const cases = @import("bitmap/test_utils/cases.zig");

pub fn make(comptime lib: type) testing.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing.T, allocator: embed.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.run("basic", CaseRunner.make(lib, cases.BasicCase, .{}));
            t.run("label", CaseRunner.make(lib, cases.LabelCase, .{}));
            t.run("button", CaseRunner.make(lib, cases.ButtonCase, .{}));
            t.run("anim", CaseRunner.make(lib, cases.AnimCase, .{}));
            t.run("suite", CaseRunner.make(lib, cases.SuiteCase, .{}));
            return t.wait();
        }

        pub fn deinit(self: *@This(), allocator: embed.mem.Allocator) void {
            _ = allocator;
            lib.testing.allocator.destroy(self);
        }
    };

    const runner = lib.testing.allocator.create(Runner) catch @panic("OOM");
    runner.* = .{};
    return testing.TestRunner.make(Runner).new(runner);
}
