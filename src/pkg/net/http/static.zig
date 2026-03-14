const std = @import("std");
const mem = std.mem;
const request_mod = @import("request.zig");
const response_mod = @import("response.zig");
const router_mod = @import("router.zig");

const Request = request_mod.Request;
const Response = response_mod.Response;

pub const EmbeddedFile = struct {
    path: []const u8,
    data: []const u8,
    mime: []const u8,
};

pub fn serveEmbedded(comptime files: []const EmbeddedFile) router_mod.Handler {
    return struct {
        fn handler(req: *Request, resp: *Response) void {
            for (files) |file| {
                if (mem.eql(u8, req.path, file.path)) {
                    _ = resp.contentType(file.mime);
                    resp.send(file.data);
                    return;
                }
            }
            resp.sendStatus(404);
        }
    }.handler;
}

pub fn mimeFromPath(path: []const u8) []const u8 {
    if (endsWith(path, ".html") or endsWith(path, ".htm")) return "text/html";
    if (endsWith(path, ".css")) return "text/css";
    if (endsWith(path, ".js")) return "application/javascript";
    if (endsWith(path, ".json")) return "application/json";
    if (endsWith(path, ".png")) return "image/png";
    if (endsWith(path, ".jpg") or endsWith(path, ".jpeg")) return "image/jpeg";
    if (endsWith(path, ".gif")) return "image/gif";
    if (endsWith(path, ".svg")) return "image/svg+xml";
    if (endsWith(path, ".ico")) return "image/x-icon";
    if (endsWith(path, ".txt")) return "text/plain";
    if (endsWith(path, ".xml")) return "application/xml";
    if (endsWith(path, ".wasm")) return "application/wasm";
    return "application/octet-stream";
}

fn endsWith(haystack: []const u8, suffix: []const u8) bool {
    return mem.endsWith(u8, haystack, suffix);
}

const testing = std.testing;

const TestWriter = struct {
    buf: [4096]u8 = undefined,
    len: usize = 0,

    pub fn writeFn(ctx: *anyopaque, data: []const u8) Response.WriteError!void {
        const self: *TestWriter = @ptrCast(@alignCast(ctx));
        const end = self.len + data.len;
        if (end > self.buf.len) return error.BufferOverflow;
        @memcpy(self.buf[self.len..end], data);
        self.len = end;
    }

    pub fn output(self: *const TestWriter) []const u8 {
        return self.buf[0..self.len];
    }
};

const test_files = [_]EmbeddedFile{
    .{ .path = "/static/app.js", .data = "console.log('hello');", .mime = "application/javascript" },
    .{ .path = "/static/style.css", .data = "body { margin: 0; }", .mime = "text/css" },
};

pub const test_exports = blk: {
    const __test_export_0 = mem;
    const __test_export_1 = request_mod;
    const __test_export_2 = response_mod;
    const __test_export_3 = router_mod;
    const __test_export_4 = Request;
    const __test_export_5 = Response;
    const __test_export_6 = endsWith;
    const __test_export_7 = TestWriter;
    const __test_export_8 = test_files;
    break :blk struct {
        pub const mem = __test_export_0;
        pub const request_mod = __test_export_1;
        pub const response_mod = __test_export_2;
        pub const router_mod = __test_export_3;
        pub const Request = __test_export_4;
        pub const Response = __test_export_5;
        pub const endsWith = __test_export_6;
        pub const TestWriter = __test_export_7;
        pub const test_files = __test_export_8;
    };
};
