pub const std = @import("base64/std.zig");
pub const url = @import("base64/url.zig");

pub const StdEncoding = std.StdEncoding;
pub const RawStdEncoding = std.RawStdEncoding;
pub const URLEncoding = std.URLEncoding;
pub const RawURLEncoding = std.RawURLEncoding;

pub const encodedLen = std.encodedLen;
pub const decodedLen = std.decodedLen;
pub const encode = std.encode;
pub const decode = std.decode;
pub const encodeWith = std.encodeWith;
pub const decodeWith = std.decodeWith;
pub fn TestRunner(comptime lib: type) @import("testing").TestRunner {
    const testing_api = @import("testing");

    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.run("std", std.TestRunner(lib));
            t.run("url", url.TestRunner(lib));
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
