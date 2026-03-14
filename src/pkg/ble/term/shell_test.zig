const std = @import("std");
const testing = std.testing;
const module = @import("shell.zig");
const test_exports = if (@hasDecl(module, "test_exports")) module.test_exports else struct {};
const CancellationToken = module.CancellationToken;
const Request = module.Request;
const ResponseWriter = module.ResponseWriter;
const HandlerFn = module.HandlerFn;
const max_commands = module.max_commands;
const max_name_len = module.max_name_len;
const Shell = module.Shell;
const ParsedCommand = module.ParsedCommand;
const parseRequest = module.parseRequest;
const encodeResponse = module.encodeResponse;
const CommandEntry = test_exports.CommandEntry;
const extractString = test_exports.extractString;
const extractU32 = test_exports.extractU32;
const copyTo = test_exports.copyTo;
const fmtU32 = test_exports.fmtU32;
const escapeJson = test_exports.escapeJson;

test "CancellationToken: init not cancelled" {
    var token = CancellationToken{};
    try std.testing.expect(!token.isCancelled());
}

test "CancellationToken: cancel and reset" {
    var token = CancellationToken{};
    token.cancel();
    try std.testing.expect(token.isCancelled());
    token.reset();
    try std.testing.expect(!token.isCancelled());
}

test "ResponseWriter: write and output" {
    var buf: [64]u8 = undefined;
    var w = ResponseWriter.init(&buf);
    w.write("hello ");
    w.write("world");
    try std.testing.expectEqualSlices(u8, "hello world", w.output());
}

test "ResponseWriter: print formatted" {
    var buf: [64]u8 = undefined;
    var w = ResponseWriter.init(&buf);
    w.print("count={d}", .{42});
    try std.testing.expectEqualSlices(u8, "count=42", w.output());
}

test "ResponseWriter: overflow truncates" {
    var buf: [5]u8 = undefined;
    var w = ResponseWriter.init(&buf);
    w.write("hello world");
    try std.testing.expectEqualSlices(u8, "hello", w.output());
}

test "Shell: register and dispatch" {
    const handler = struct {
        pub fn serve(req: *const Request, w: *ResponseWriter) void {
            _ = req;
            w.write("ok");
        }
    }.serve;

    var shell = Shell.init();
    try shell.register("echo", handler, null);

    var cancel = CancellationToken{};
    var resp_buf: [256]u8 = undefined;
    const writer = shell.dispatch("echo", "", 1, 0x40, &cancel, &resp_buf);
    try std.testing.expectEqualSlices(u8, "ok", writer.output());
    try std.testing.expectEqual(@as(i8, 0), writer.exit_code);
}

test "Shell: unknown command sets error" {
    var shell = Shell.init();
    var cancel = CancellationToken{};
    var resp_buf: [256]u8 = undefined;
    const writer = shell.dispatch("nonexistent", "", 1, 0x40, &cancel, &resp_buf);
    try std.testing.expectEqual(@as(i8, 1), writer.exit_code);
    try std.testing.expectEqualSlices(u8, "unknown command", writer.err_msg);
}

test "Shell: handler receives args and user_ctx" {
    const Counter = struct { value: u32 = 0 };
    var counter = Counter{};

    const handler = struct {
        pub fn serve(req: *const Request, w: *ResponseWriter) void {
            const ctr: *Counter = @ptrCast(@alignCast(req.user_ctx));
            ctr.value += 1;
            w.print("args={s}", .{req.args});
        }
    }.serve;

    var shell = Shell.init();
    try shell.register("test", handler, @ptrCast(&counter));

    var cancel = CancellationToken{};
    var resp_buf: [256]u8 = undefined;
    const writer = shell.dispatch("test", "foo bar", 1, 0x40, &cancel, &resp_buf);
    try std.testing.expectEqualSlices(u8, "args=foo bar", writer.output());
    try std.testing.expectEqual(@as(u32, 1), counter.value);
}

test "parseRequest: valid JSON" {
    const parsed = parseRequest("{\"cmd\":\"ls -la\",\"id\":42}") orelse unreachable;
    try std.testing.expectEqualSlices(u8, "ls", parsed.cmd);
    try std.testing.expectEqualSlices(u8, "-la", parsed.args);
    try std.testing.expectEqual(@as(u32, 42), parsed.id);
}

test "parseRequest: no args" {
    const parsed = parseRequest("{\"cmd\":\"sys.info\",\"id\":1}") orelse unreachable;
    try std.testing.expectEqualSlices(u8, "sys.info", parsed.cmd);
    try std.testing.expectEqualSlices(u8, "", parsed.args);
    try std.testing.expectEqual(@as(u32, 1), parsed.id);
}

test "parseRequest: invalid JSON returns null" {
    try std.testing.expect(parseRequest("garbage") == null);
    try std.testing.expect(parseRequest("{}") == null);
    try std.testing.expect(parseRequest("{\"cmd\":\"ls\"}") == null);
}

test "encodeResponse: basic" {
    var buf: [256]u8 = undefined;
    const resp = encodeResponse(&buf, 1, "file1\nfile2", "", 0);
    try std.testing.expectEqualSlices(u8, "{\"id\":1,\"out\":\"file1\\nfile2\",\"err\":\"\",\"exit\":0}", resp);
}

test "encodeResponse: with error" {
    var buf: [256]u8 = undefined;
    const resp = encodeResponse(&buf, 5, "", "not found", 1);
    try std.testing.expectEqualSlices(u8, "{\"id\":5,\"out\":\"\",\"err\":\"not found\",\"exit\":1}", resp);
}

test "encodeResponse: negative exit code" {
    var buf: [256]u8 = undefined;
    const resp = encodeResponse(&buf, 1, "", "killed", -1);
    try std.testing.expectEqualSlices(u8, "{\"id\":1,\"out\":\"\",\"err\":\"killed\",\"exit\":-1}", resp);
}
