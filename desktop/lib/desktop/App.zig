const dep = @import("dep");
const std = dep.embed_std.std;
const desktop_http = @import("../http.zig");

const App = @This();

address: desktop_http.AddrPort,
server: desktop_http.Server,

pub const Options = struct {
    address: desktop_http.AddrPort,
    assets_dir: ?[]const u8 = null,
};

pub fn init(allocator: std.mem.Allocator, options: Options) !App {
    return .{
        .address = options.address,
        .server = try desktop_http.Server.init(allocator, .{
            .assets_dir = options.assets_dir,
        }),
    };
}

pub fn deinit(self: *App) void {
    self.server.deinit();
    self.* = undefined;
}

pub fn serve(self: *App, listener: desktop_http.Listener) !void {
    try self.server.serve(listener);
}

pub fn listenAndServe(self: *App) !void {
    try self.server.listenAndServe(self.address);
}

pub fn close(self: *App) void {
    self.server.close();
}

pub fn TestRunner(comptime lib: type) dep.testing.TestRunner {
    const testing_api = dep.testing;

    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = t;
            _ = allocator;
            return true;
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
