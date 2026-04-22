const testing_api = @import("testing");
const Header = @import("../../http/Header.zig");
const ReadCloser = @import("../../http/ReadCloser.zig");
const Request = @import("../../http/Request.zig");
const Response = @import("../../http/Response.zig");
const Handler = @import("../../http/Handler.zig");
const ServeMux = @import("../../http/ServeMux.zig");
const StaticServeMux = @import("../../http/StaticServeMux.zig");
const ResponseWriter = @import("../../http/ResponseWriter.zig");
const Server = @import("../../http/Server.zig");
const Client = @import("../../http/Client.zig");
const Transport = @import("../../http/Transport.zig");
const status = @import("../../http/status.zig");

pub fn make(comptime lib: type) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.parallel();
            t.run("Header", Header.TestRunner(lib));
            t.run("ReadCloser", ReadCloser.TestRunner(lib));
            t.run("Request", Request.TestRunner(lib));
            t.run("Response", Response.TestRunner(lib));
            t.run("Handler", Handler.TestRunner(lib));
            t.run("ServeMux", ServeMux.TestRunner(lib));
            t.run("StaticServeMux", StaticServeMux.TestRunner(lib));
            t.run("ResponseWriter", ResponseWriter.TestRunner(lib));
            t.run("Server", Server.TestRunner(lib));
            t.run("Client", Client.TestRunner(lib));
            t.run("Transport", Transport.TestRunner(lib));
            t.run("status", status.TestRunner(lib));
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
