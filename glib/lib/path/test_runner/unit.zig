const path = @import("../../path.zig");
const testing_api = @import("testing");

pub fn make(comptime std: type) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            std.testing.expectEqualStrings("file.txt", path.baseName("/extflash/a/file.txt")) catch |err| return fail(t, err);
            std.testing.expectEqualStrings("file.txt", path.baseName("/extflash/a/file.txt/")) catch |err| return fail(t, err);
            std.testing.expectEqualStrings("/extflash/a", path.dirName("/extflash/a/file.txt")) catch |err| return fail(t, err);
            std.testing.expectEqualStrings("/", path.dirName("/file.txt")) catch |err| return fail(t, err);
            std.testing.expectEqualStrings(".", path.dirName("file.txt")) catch |err| return fail(t, err);
            std.testing.expectEqualStrings(".txt", path.extName("/extflash/a/file.txt")) catch |err| return fail(t, err);
            std.testing.expectEqualStrings("", path.extName(".profile")) catch |err| return fail(t, err);

            var buf: [64]u8 = undefined;
            std.testing.expectEqualStrings("/extflash/a/file.txt", path.join(&buf, "/extflash/", "/a/file.txt") catch |err| return fail(t, err)) catch |err| return fail(t, err);
            std.testing.expectEqualStrings("/file.txt", path.join(&buf, "/", "file.txt") catch |err| return fail(t, err)) catch |err| return fail(t, err);
            std.testing.expectEqualStrings("a/file.txt", path.join(&buf, "a", "file.txt") catch |err| return fail(t, err)) catch |err| return fail(t, err);
            return true;
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }

        fn fail(t: *testing_api.T, err: anyerror) bool {
            t.logFatal(@errorName(err));
            return false;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}
