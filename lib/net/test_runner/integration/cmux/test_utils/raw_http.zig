const io = @import("io");
const net_mod = @import("../../../../../net.zig");

pub const RequestHeader = struct {
    name: []const u8,
    value: []const u8,
};

pub const Request = struct {
    method: []const u8 = "GET",
    target: []const u8,
    headers: []const RequestHeader = &.{},
    body: []const u8 = "",
};

pub const RawResponse = struct {
    head: []u8,
    body: []u8,
};

pub fn writeRawRequest(
    comptime lib: type,
    alloc: lib.mem.Allocator,
    conn: *net_mod.Conn,
    request: Request,
) !void {
    var bytes = lib.ArrayList(u8){};
    defer bytes.deinit(alloc);

    const start_line = try lib.fmt.allocPrint(
        alloc,
        "{s} {s} HTTP/1.1\r\n",
        .{ request.method, request.target },
    );
    defer alloc.free(start_line);
    try bytes.appendSlice(alloc, start_line);

    var has_host = false;
    var has_connection = false;
    var has_content_length = false;
    for (request.headers) |header| {
        if (lib.ascii.eqlIgnoreCase(header.name, "host")) has_host = true;
        if (lib.ascii.eqlIgnoreCase(header.name, "connection")) has_connection = true;
        if (lib.ascii.eqlIgnoreCase(header.name, "content-length")) has_content_length = true;

        const line = try lib.fmt.allocPrint(
            alloc,
            "{s}: {s}\r\n",
            .{ header.name, header.value },
        );
        defer alloc.free(line);
        try bytes.appendSlice(alloc, line);
    }

    if (!has_host) try bytes.appendSlice(alloc, "Host: example.com\r\n");
    if (!has_connection) try bytes.appendSlice(alloc, "Connection: close\r\n");
    if (request.body.len != 0 and !has_content_length) {
        const content_length = try lib.fmt.allocPrint(
            alloc,
            "Content-Length: {d}\r\n",
            .{request.body.len},
        );
        defer alloc.free(content_length);
        try bytes.appendSlice(alloc, content_length);
    }

    try bytes.appendSlice(alloc, "\r\n");
    try bytes.appendSlice(alloc, request.body);
    try io.writeAll(net_mod.Conn, conn, bytes.items);
}

pub fn readRawResponse(
    comptime lib: type,
    alloc: lib.mem.Allocator,
    conn: net_mod.Conn,
) !RawResponse {
    const http_ns = net_mod.make(lib).http;
    var c = conn;
    var bytes = try lib.ArrayList(u8).initCapacity(alloc, 0);
    defer bytes.deinit(alloc);
    var buf: [256]u8 = undefined;

    var head_end: ?usize = null;
    while (head_end == null) {
        const n = try c.read(&buf);
        if (n == 0) return error.EndOfStream;
        try bytes.appendSlice(alloc, buf[0..n]);
        if (lib.mem.indexOf(u8, bytes.items, "\r\n\r\n")) |end| head_end = end;
    }

    const split = head_end.? + 4;
    const head = try alloc.dupe(u8, bytes.items[0..split]);
    errdefer alloc.free(head);
    const prefix = bytes.items[split..];
    const status_code = try responseStatusCode(lib, head);

    if (!responseBodyAllowed(http_ns, status_code)) {
        return .{
            .head = head,
            .body = try alloc.dupe(u8, prefix),
        };
    }

    if (headerValue(lib, http_ns, head, http_ns.Header.content_length)) |value| {
        const content_length = try lib.fmt.parseInt(usize, value, 10);
        const body = try readFixedBody(lib, alloc, c, prefix, content_length);
        return .{ .head = head, .body = body };
    }
    if (headerValue(lib, http_ns, head, http_ns.Header.transfer_encoding)) |value| {
        if (lib.ascii.eqlIgnoreCase(value, "chunked")) {
            const body = try readChunkedBody(lib, alloc, c, prefix);
            return .{ .head = head, .body = body };
        }
    }
    const body = try readToEof(lib, alloc, c, prefix);
    return .{
        .head = head,
        .body = body,
    };
}

pub fn responseStatusCode(comptime lib: type, head: []const u8) !u16 {
    const line = firstLine(lib, head);
    var parts = lib.mem.tokenizeAny(u8, line, " ");
    _ = parts.next() orelse return error.BadResponse;
    const code = parts.next() orelse return error.BadResponse;
    return try lib.fmt.parseInt(u16, code, 10);
}

pub fn firstLine(comptime lib: type, head: []const u8) []const u8 {
    const end = lib.mem.indexOf(u8, head, "\r\n") orelse head.len;
    return head[0..end];
}

pub fn headerValue(
    comptime lib: type,
    comptime http_ns: type,
    head: []const u8,
    name: []const u8,
) ?[]const u8 {
    var line_start: usize = 0;
    while (line_start < head.len) {
        const rel_end = lib.mem.indexOf(u8, head[line_start..], "\r\n") orelse head.len - line_start;
        const line = head[line_start .. line_start + rel_end];
        const colon = lib.mem.indexOfScalar(u8, line, ':') orelse {
            if (line_start + rel_end == head.len) break;
            line_start += rel_end + 2;
            continue;
        };
        const header_name = lib.mem.trim(u8, line[0..colon], " ");
        if (http_ns.Header.init(header_name, "").is(name)) {
            return lib.mem.trim(u8, line[colon + 1 ..], " ");
        }
        if (line_start + rel_end == head.len) break;
        line_start += rel_end + 2;
    }
    return null;
}

pub fn expectConnClosed(comptime lib: type, conn: net_mod.Conn) !void {
    const testing = lib.testing;
    var c = conn;
    c.setReadTimeout(20);

    var buf: [1]u8 = undefined;
    const n = c.read(&buf) catch |err| switch (err) {
        error.EndOfStream,
        error.ConnectionReset,
        error.BrokenPipe,
        => 0,
        else => return err,
    };
    try testing.expectEqual(@as(usize, 0), n);

    _ = c.write("x") catch |err| switch (err) {
        error.BrokenPipe,
        error.ConnectionReset,
        error.ConnectionRefused,
        => return,
        else => return err,
    };
    return error.TestUnexpectedResult;
}

fn readFixedBody(
    comptime lib: type,
    alloc: lib.mem.Allocator,
    conn: net_mod.Conn,
    prefix: []const u8,
    total_len: usize,
) ![]u8 {
    var out = try lib.ArrayList(u8).initCapacity(alloc, total_len);
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, prefix[0..@min(prefix.len, total_len)]);
    var c = conn;
    var buf: [256]u8 = undefined;
    while (out.items.len < total_len) {
        const want = @min(buf.len, total_len - out.items.len);
        const n = try c.read(buf[0..want]);
        if (n == 0) return error.EndOfStream;
        try out.appendSlice(alloc, buf[0..n]);
    }
    return out.toOwnedSlice(alloc);
}

fn readChunkedBody(
    comptime lib: type,
    alloc: lib.mem.Allocator,
    conn: net_mod.Conn,
    prefix: []const u8,
) ![]u8 {
    var stream = io.PrefixReader(net_mod.Conn).init(conn, prefix);
    var body = lib.ArrayList(u8){};
    defer body.deinit(alloc);
    var line_buf: [128]u8 = undefined;
    while (true) {
        const line = try stream.readLine(&line_buf);
        const semi = lib.mem.indexOfScalar(u8, line, ';') orelse line.len;
        const size = try lib.fmt.parseInt(usize, lib.mem.trim(u8, line[0..semi], " "), 16);
        if (size == 0) {
            try stream.expectCrlf();
            break;
        }
        const chunk = try alloc.alloc(u8, size);
        defer alloc.free(chunk);
        try io.readFull(@TypeOf(stream), &stream, chunk);
        try body.appendSlice(alloc, chunk);
        try stream.expectCrlf();
    }
    return body.toOwnedSlice(alloc);
}

fn readToEof(
    comptime lib: type,
    alloc: lib.mem.Allocator,
    conn: net_mod.Conn,
    prefix: []const u8,
) ![]u8 {
    var out = lib.ArrayList(u8){};
    defer out.deinit(alloc);
    try out.appendSlice(alloc, prefix);

    var c = conn;
    var buf: [256]u8 = undefined;
    while (true) {
        const n = c.read(&buf) catch |err| switch (err) {
            error.EndOfStream => 0,
            else => return err,
        };
        if (n == 0) break;
        try out.appendSlice(alloc, buf[0..n]);
    }
    return out.toOwnedSlice(alloc);
}

fn responseBodyAllowed(comptime http_ns: type, status_code: u16) bool {
    if (status_code >= 100 and status_code < 200) return false;
    if (status_code == http_ns.status.no_content or status_code == http_ns.status.not_modified) return false;
    return true;
}
