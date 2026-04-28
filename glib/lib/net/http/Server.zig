//! Server — HTTP/1.1 server built on `net.Listener` / `net.Conn`.

const time_mod = @import("time");
const io = @import("io");
const context_mod = @import("context");
const Conn = @import("../Conn.zig");
const Listener = @import("../Listener.zig");
const Header = @import("Header.zig");
const Request = @import("Request.zig");
const ReadCloser = @import("ReadCloser.zig");
const ResponseWriter = @import("ResponseWriter.zig").ResponseWriter;
const handler_mod = @import("Handler.zig");
const serve_mux_mod = @import("ServeMux.zig");
const status = @import("status.zig");
const textproto_reader_mod = @import("../textproto/Reader.zig");
const testing_api = @import("testing");
const url_mod = @import("../url.zig");
const BufferedConnReader = io.BufferedReader(Conn);
const TextprotoReader = textproto_reader_mod.Reader(BufferedConnReader);

pub fn Server(comptime std: type, comptime net: type) type {
    const Allocator = std.mem.Allocator;
    const Thread = std.Thread;
    const Context = context_mod.Context;
    const ContextNs = context_mod.make(std, net.time);
    const Handler = handler_mod.Handler(std);
    const HandlerFunc = handler_mod.HandlerFunc(std);
    const ServeMux = serve_mux_mod.ServeMux(std);
    const Writer = ResponseWriter(std);
    return struct {
        allocator: Allocator,
        options: Options,
        shared: *SharedState,
        contexts: ContextNs,
        handler: Handler,
        owned_mux: ?*ServeMux = null,

        const Self = @This();

        pub const Options = struct {
            handler: ?Handler = null,
            spawn_config: Thread.SpawnConfig = .{},
            read_header_timeout: ?time_mod.duration.Duration = null,
            read_timeout: ?time_mod.duration.Duration = null,
            write_timeout: ?time_mod.duration.Duration = null,
            idle_timeout: ?time_mod.duration.Duration = null,
            max_header_bytes: usize = 32 * 1024,
        };

        pub const HandleError = ServeMux.HandleError || error{
            NoDefaultHandler,
        };

        const ConnEntry = struct {
            id: usize,
            conn: Conn,
            idle: bool = false,
        };

        const SharedState = struct {
            mutex: Thread.Mutex = .{},
            cond: Thread.Condition = .{},
            listener: ?Listener = null,
            serving: bool = false,
            closed_permanently: bool = false,
            graceful_shutdown: bool = false,
            hard_close: bool = false,
            next_conn_id: usize = 1,
            active_workers: usize = 0,
            conns: std.ArrayList(ConnEntry) = .{},
        };

        const RequestBodyMode = union(enum) {
            fixed: usize,
            chunked: ChunkedState,
        };

        const ChunkedState = struct {
            remaining_in_chunk: usize = 0,
            final_chunk_seen: bool = false,
        };

        pub const RequestBodyState = struct {
            buffered: *BufferedConnReader,
            mode: RequestBodyMode,
            complete: bool = false,
            closed: bool = false,

            pub fn read(self: *@This(), buf: []u8) anyerror!usize {
                if (self.closed or buf.len == 0) return 0;
                return switch (self.mode) {
                    .fixed => |*remaining| self.readFixed(buf, remaining),
                    .chunked => |*chunked| self.readChunked(buf, chunked),
                };
            }

            pub fn close(self: *@This()) void {
                self.closed = true;
            }

            fn readFixed(self: *@This(), buf: []u8, remaining: *usize) anyerror!usize {
                if (remaining.* == 0) {
                    self.complete = true;
                    return 0;
                }
                const n = try self.readFromBuffered(buf[0..@min(buf.len, remaining.*)]);
                if (n == 0) return error.EndOfStream;
                remaining.* -= n;
                if (remaining.* == 0) self.complete = true;
                return n;
            }

            fn readChunked(self: *@This(), buf: []u8, chunked: *ChunkedState) anyerror!usize {
                if (chunked.final_chunk_seen) {
                    self.complete = true;
                    return 0;
                }
                if (chunked.remaining_in_chunk == 0) {
                    var line_buf: [128]u8 = undefined;
                    const raw_line = try self.readBufferedLine(&line_buf);
                    const semi = std.mem.indexOfScalar(u8, raw_line, ';') orelse raw_line.len;
                    const size_text = std.mem.trim(u8, raw_line[0..semi], " ");
                    const chunk_size = try std.fmt.parseInt(usize, size_text, 16);
                    if (chunk_size == 0) {
                        while (true) {
                            const trailer = try self.readBufferedLine(&line_buf);
                            if (trailer.len == 0) break;
                        }
                        chunked.final_chunk_seen = true;
                        self.complete = true;
                        return 0;
                    }
                    chunked.remaining_in_chunk = chunk_size;
                }

                const n = try self.readFromBuffered(buf[0..@min(buf.len, chunked.remaining_in_chunk)]);
                if (n == 0) return error.EndOfStream;
                chunked.remaining_in_chunk -= n;
                if (chunked.remaining_in_chunk == 0) try self.expectBufferedCrlf();
                return n;
            }

            fn readFromBuffered(self: *@This(), buf: []u8) anyerror!usize {
                return self.buffered.ioReader().readSliceShort(buf) catch |err| switch (err) {
                    error.ReadFailed => return self.buffered.err() orelse error.Unexpected,
                    else => return err,
                };
            }

            fn readBufferedByte(self: *@This()) anyerror!u8 {
                var one: [1]u8 = undefined;
                const n = try self.readFromBuffered(&one);
                if (n == 0) return error.EndOfStream;
                return one[0];
            }

            fn readBufferedLine(self: *@This(), out: []u8) anyerror![]const u8 {
                const raw = self.buffered.ioReader().takeDelimiterInclusive('\n') catch |err| switch (err) {
                    error.ReadFailed => return self.buffered.err() orelse error.Unexpected,
                    else => return err,
                };
                if (raw.len < 2 or raw[raw.len - 2] != '\r') return error.InvalidResponse;
                const line = raw[0 .. raw.len - 2];
                if (line.len > out.len) return error.BufferTooSmall;
                @memcpy(out[0..line.len], line);
                return out[0..line.len];
            }

            fn expectBufferedCrlf(self: *@This()) anyerror!void {
                if (try self.readBufferedByte() != '\r') return error.InvalidResponse;
                if (try self.readBufferedByte() != '\n') return error.InvalidResponse;
            }
        };

        const ParsedRequestState = struct {
            allocator: Allocator,
            raw_head: []u8,
            req: Request,
            ctx: ?Context = null,
            body_state: ?*RequestBodyState = null,

            fn bodyComplete(self: *const @This()) bool {
                return if (self.body_state) |body_state| body_state.complete else true;
            }

            fn deinit(self: *@This()) void {
                if (self.req.body_reader) |body| body.close();
                if (self.ctx) |ctx| {
                    ctx.cancel();
                    ctx.deinit();
                }
                if (self.body_state) |body_state| self.allocator.destroy(body_state);
                self.req.deinit();
                self.allocator.free(self.raw_head);
                self.* = undefined;
            }
        };

        pub fn init(allocator: Allocator, options: Options) Allocator.Error!Self {
            const shared = try allocator.create(SharedState);
            errdefer allocator.destroy(shared);
            shared.* = .{};

            var contexts = try ContextNs.init(allocator);
            errdefer contexts.deinit();

            var self = Self{
                .allocator = allocator,
                .options = options,
                .shared = shared,
                .contexts = contexts,
                .handler = undefined,
            };

            if (options.handler) |handler| {
                self.handler = handler;
            } else {
                const mux = try allocator.create(ServeMux);
                errdefer allocator.destroy(mux);
                mux.* = ServeMux.init(allocator);
                self.owned_mux = mux;
                self.handler = mux.handler();
            }

            return self;
        }

        pub fn deinit(self: *Self) void {
            self.close();
            self.waitForWorkers();

            if (self.owned_mux) |mux| {
                mux.deinit();
                self.allocator.destroy(mux);
            }
            self.contexts.deinit();
            self.shared.conns.deinit(self.allocator);
            self.allocator.destroy(self.shared);
            self.* = undefined;
        }

        pub fn handle(self: *Self, pattern: []const u8, handler: Handler) HandleError!void {
            const mux = self.owned_mux orelse return error.NoDefaultHandler;
            try mux.handle(pattern, handler);
        }

        pub fn handleFunc(self: *Self, pattern: []const u8, func: HandlerFunc) HandleError!void {
            const mux = self.owned_mux orelse return error.NoDefaultHandler;
            try mux.handleFunc(pattern, func);
        }

        pub fn serve(self: *Self, listener: Listener) anyerror!void {
            try self.beginServe(listener);
            var serve_err: anyerror = error.ServerClosed;
            defer {
                self.waitForWorkers();
                self.finishServe();
            }

            listener.listen() catch |err| {
                serve_err = err;
                return serve_err;
            };

            while (true) {
                const conn = listener.accept() catch |err| {
                    if (self.acceptReturnsClosed(err)) {
                        serve_err = error.ServerClosed;
                        return serve_err;
                    }
                    if (isTransientAcceptError(err)) continue;
                    self.initiateHardClose();
                    serve_err = err;
                    return serve_err;
                };

                const conn_id = self.registerConn(conn) catch |err| {
                    var doomed = conn;
                    doomed.deinit();
                    self.initiateHardClose();
                    serve_err = err;
                    return serve_err;
                };
                const thread = Thread.spawn(self.options.spawn_config, Self.connectionWorker, .{ self, conn, conn_id }) catch |err| {
                    self.unregisterConn(conn_id);
                    var doomed = conn;
                    doomed.deinit();
                    self.initiateHardClose();
                    serve_err = err;
                    return serve_err;
                };
                thread.detach();
            }
        }

        pub fn close(self: *Self) void {
            self.initiateHardClose();
        }

        pub fn shutdown(self: *Self, ctx: Context) ?anyerror {
            var listener: ?Listener = null;

            self.shared.mutex.lock();
            if (!self.shared.graceful_shutdown and !self.shared.hard_close) {
                self.shared.closed_permanently = true;
                self.shared.graceful_shutdown = true;
                listener = self.shared.listener;
                for (self.shared.conns.items) |entry| {
                    if (entry.idle) entry.conn.close();
                }
                self.shared.cond.broadcast();
            }
            self.shared.mutex.unlock();

            if (listener) |ln| ln.close();

            while (true) {
                self.shared.mutex.lock();
                if (self.shared.active_workers == 0) {
                    self.shared.mutex.unlock();
                    return null;
                }
                self.shared.mutex.unlock();

                if (ctx.err()) |err| {
                    self.initiateHardClose();
                    self.waitForWorkers();
                    return err;
                }

                self.shared.mutex.lock();
                self.shared.cond.timedWait(&self.shared.mutex, @intCast(5 * net.time.duration.MilliSecond)) catch {};
                self.shared.mutex.unlock();
            }
        }

        fn beginServe(self: *Self, listener: Listener) !void {
            self.shared.mutex.lock();
            defer self.shared.mutex.unlock();
            if (self.shared.serving) return error.AlreadyServing;
            if (self.shared.closed_permanently) return error.ServerClosed;
            self.shared.serving = true;
            self.shared.listener = listener;
        }

        fn finishServe(self: *Self) void {
            self.shared.mutex.lock();
            defer self.shared.mutex.unlock();
            self.shared.serving = false;
            self.shared.listener = null;
            self.shared.cond.broadcast();
        }

        fn waitForWorkers(self: *Self) void {
            self.shared.mutex.lock();
            defer self.shared.mutex.unlock();
            while (self.shared.active_workers != 0) self.shared.cond.wait(&self.shared.mutex);
        }

        fn acceptReturnsClosed(self: *Self, err: anyerror) bool {
            self.shared.mutex.lock();
            const closing = self.shared.graceful_shutdown or self.shared.hard_close;
            self.shared.mutex.unlock();
            if (!closing) return false;
            return err == error.Closed or err == error.SocketNotListening;
        }

        fn registerConn(self: *Self, conn: Conn) Allocator.Error!usize {
            self.shared.mutex.lock();
            defer self.shared.mutex.unlock();
            const id = self.shared.next_conn_id;
            self.shared.next_conn_id += 1;
            self.shared.active_workers += 1;
            try self.shared.conns.append(self.allocator, .{
                .id = id,
                .conn = conn,
                .idle = false,
            });
            return id;
        }

        fn unregisterConn(self: *Self, conn_id: usize) void {
            self.shared.mutex.lock();
            defer self.shared.mutex.unlock();

            var index: ?usize = null;
            for (self.shared.conns.items, 0..) |entry, i| {
                if (entry.id == conn_id) {
                    index = i;
                    break;
                }
            }
            if (index) |i| _ = self.shared.conns.swapRemove(i);
            std.debug.assert(self.shared.active_workers > 0);
            self.shared.active_workers -= 1;
            if (self.shared.active_workers == 0) self.shared.cond.broadcast();
        }

        fn setConnIdle(self: *Self, conn_id: usize, idle: bool) void {
            self.shared.mutex.lock();
            defer self.shared.mutex.unlock();
            for (self.shared.conns.items) |*entry| {
                if (entry.id == conn_id) {
                    entry.idle = idle;
                    break;
                }
            }
        }

        fn shouldStopBeforeNextRequest(self: *Self) bool {
            self.shared.mutex.lock();
            defer self.shared.mutex.unlock();
            return self.shared.graceful_shutdown or self.shared.hard_close;
        }

        fn initiateHardClose(self: *Self) void {
            var listener: ?Listener = null;

            self.shared.mutex.lock();
            self.shared.closed_permanently = true;
            self.shared.hard_close = true;
            listener = self.shared.listener;
            for (self.shared.conns.items) |entry| entry.conn.close();
            self.shared.cond.broadcast();
            self.shared.mutex.unlock();

            if (listener) |ln| ln.close();
        }

        fn shouldAttemptKeepAlive(self: *Self, req: *const Request) bool {
            _ = self;
            if (req.close) return false;
            return req.proto_major == 1 and req.proto_minor == 1;
        }

        fn shouldReuseConn(self: *Self, req: *const Request, rw: *const Writer, body_complete: bool) bool {
            if (!body_complete) return false;
            if (!rw.wantsKeepAlive()) return false;
            if (!self.shouldAttemptKeepAlive(req)) return false;
            return !self.shouldStopBeforeNextRequest();
        }

        fn connectionWorker(self: *Self, conn: Conn, conn_id: usize) void {
            var owned_conn = conn;
            defer owned_conn.deinit();
            defer self.unregisterConn(conn_id);

            var buffered = BufferedConnReader.initAlloc(&owned_conn, self.allocator, self.options.max_header_bytes) catch return;
            defer buffered.deinit();

            var first_request = true;
            while (true) {
                if (!first_request and self.shouldStopBeforeNextRequest()) break;
                self.setConnIdle(conn_id, !first_request);

                var parsed = self.readNextRequest(owned_conn, &buffered, first_request) catch |err| switch (err) {
                    error.EndOfStream,
                    error.ConnectionReset,
                    error.ConnectionRefused,
                    error.BrokenPipe,
                    error.Closed,
                    error.SocketNotListening,
                    => return,
                    error.TimedOut => return,
                    error.BadRequest,
                    error.BufferTooSmall,
                    error.InvalidCharacter,
                    => {
                        writeBareResponse(std, owned_conn, status.bad_request, true);
                        return;
                    },
                    else => return,
                };
                defer parsed.deinit();
                self.setConnIdle(conn_id, false);
                first_request = false;

                if (self.options.write_timeout) |timeout| owned_conn.setWriteDeadline(time_mod.instant.add(net.time.instant.now(), timeout));
                defer owned_conn.setWriteDeadline(null);

                var rw = Writer.init(self.allocator, owned_conn, &parsed.req, self.shouldAttemptKeepAlive(&parsed.req));
                defer rw.deinit();

                self.handler.serveHTTP(&rw, &parsed.req);
                rw.finish() catch return;

                if (!self.shouldReuseConn(&parsed.req, &rw, parsed.bodyComplete())) return;
            }
        }

        fn readNextRequest(self: *Self, conn: Conn, buffered: *BufferedConnReader, first_request: bool) anyerror!ParsedRequestState {
            if (first_request) {
                if (self.options.read_header_timeout) |timeout| conn.setReadDeadline(time_mod.instant.add(net.time.instant.now(), timeout));
            } else if (self.options.idle_timeout) |timeout| {
                conn.setReadDeadline(time_mod.instant.add(net.time.instant.now(), timeout));
            } else if (self.options.read_header_timeout) |timeout| {
                conn.setReadDeadline(time_mod.instant.add(net.time.instant.now(), timeout));
            } else {
                conn.setReadDeadline(null);
            }

            const raw = try readRequestHead(self.allocator, buffered, self.options.max_header_bytes);
            errdefer self.allocator.free(raw);

            var req = try parseRequest(std, self.allocator, raw);
            errdefer req.deinit();

            const request_ctx = try self.contexts.withCancel(self.contexts.background());
            req.ctx = request_ctx;

            if (self.options.read_timeout) |timeout| conn.setReadDeadline(time_mod.instant.add(net.time.instant.now(), timeout));

            var parsed: ParsedRequestState = .{
                .allocator = self.allocator,
                .raw_head = raw,
                .req = req,
                .ctx = request_ctx,
            };

            if (requestHasBody(&parsed.req)) {
                const body_state = try self.allocator.create(RequestBodyState);
                errdefer self.allocator.destroy(body_state);
                body_state.* = try initRequestBody(std, net, buffered, &parsed.req);
                parsed.body_state = body_state;
                parsed.req.body_reader = ReadCloser.init(body_state);
            }

            return parsed;
        }
    };
}

fn isTransientAcceptError(err: anyerror) bool {
    return err == error.ConnectionAborted or err == error.ConnectionResetByPeer or err == error.WouldBlock;
}

fn requestHasBody(req: *const Request) bool {
    return req.content_length > 0 or req.transfer_encoding.len != 0;
}

fn initRequestBody(comptime std: type, comptime net: type, buffered: *io.BufferedReader(Conn), req: *const Request) !Server(std, net).RequestBodyState {
    if (headerValue(req.header, Header.transfer_encoding)) |value| {
        if (!std.ascii.eqlIgnoreCase(value, "chunked")) return error.BadRequest;
        return .{
            .buffered = buffered,
            .mode = .{ .chunked = .{} },
        };
    }
    return .{
        .buffered = buffered,
        .mode = .{ .fixed = @intCast(req.content_length) },
    };
}

fn readRequestHead(allocator: anytype, buffered: *BufferedConnReader, max_header_bytes: usize) ![]u8 {
    var reader = TextprotoReader.fromBuffered(buffered);
    const raw = reader.takeHeaderBlockMax(max_header_bytes, .{}) catch |err| switch (err) {
        error.InvalidLineEnding => return error.BadRequest,
        error.BufferTooSmall => return error.BufferTooSmall,
        else => return err,
    };
    return allocator.dupe(u8, raw);
}

fn parseRequest(comptime std: type, allocator: anytype, head: []u8) !Request {
    const line_end = std.mem.indexOf(u8, head, "\r\n") orelse return error.BadRequest;
    const request_line = head[0..line_end];
    var parts_it = std.mem.tokenizeAny(u8, request_line, " ");
    const method = parts_it.next() orelse return error.BadRequest;
    const target = parts_it.next() orelse return error.BadRequest;
    const proto = parts_it.next() orelse return error.BadRequest;
    if (parts_it.next() != null) return error.BadRequest;

    const proto_parts = parseProto(std, proto) orelse return error.BadRequest;
    const headers = try parseHeaders(std, allocator, head[line_end + 2 ..]);
    errdefer allocator.free(headers);

    const host = headerValue(headers, Header.host) orelse "";
    const parsed_url = try parseRequestTarget(std, target, host);

    var req: Request = .{
        .allocator = allocator,
        .method = method,
        .url = parsed_url,
        .proto = proto,
        .proto_major = proto_parts.major,
        .proto_minor = proto_parts.minor,
        .header = headers,
        .owned_header_storage = headers,
        .request_uri = target,
        .host = host,
        .close = shouldCloseConnection(std, headers, proto_parts.major, proto_parts.minor),
    };

    if (headerValue(headers, Header.content_length)) |value| {
        const content_length = try std.fmt.parseInt(i64, value, 10);
        if (content_length < 0) return error.BadRequest;
        if (@as(u64, @intCast(content_length)) > std.math.maxInt(usize)) return error.BadRequest;
        req.content_length = content_length;
    }
    if (headerValue(headers, Header.transfer_encoding)) |value| {
        if (!std.ascii.eqlIgnoreCase(value, "chunked")) return error.BadRequest;
        if (req.content_length != 0) return error.BadRequest;
        req.transfer_encoding = chunked_transfer_encoding[0..];
    }
    return req;
}

const chunked_transfer_encoding = [_][]const u8{"chunked"};

fn parseHeaders(comptime std: type, allocator: anytype, lines: []u8) ![]Header {
    var headers = std.ArrayList(Header){};
    defer headers.deinit(allocator);

    var start: usize = 0;
    while (start <= lines.len) {
        const rel_end = std.mem.indexOf(u8, lines[start..], "\r\n") orelse lines.len - start;
        const line = lines[start .. start + rel_end];
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.BadRequest;
        const name = std.mem.trim(u8, line[0..colon], " ");
        const value = std.mem.trim(u8, line[colon + 1 ..], " ");
        try headers.append(allocator, Header.init(name, value));
        if (start + rel_end == lines.len) break;
        start += rel_end + 2;
    }
    return headers.toOwnedSlice(allocator);
}

fn parseRequestTarget(comptime std: type, target: []const u8, host: []const u8) !url_mod.Url {
    if (std.mem.indexOf(u8, target, "://") != null) return try url_mod.parse(target);

    var rest = target;
    var fragment: []const u8 = "";
    var query: []const u8 = "";

    if (std.mem.indexOfScalar(u8, rest, '#')) |hash| {
        fragment = rest[hash + 1 ..];
        rest = rest[0..hash];
    }
    if (std.mem.indexOfScalar(u8, rest, '?')) |q| {
        query = rest[q + 1 ..];
        rest = rest[0..q];
    }

    return .{
        .raw = target,
        .scheme = "",
        .username = "",
        .password = "",
        .host = host,
        .port = "",
        .path = if (rest.len == 0) "/" else rest,
        .raw_query = query,
        .fragment = fragment,
    };
}

fn parseProto(comptime std: type, proto: []const u8) ?struct { major: u8, minor: u8 } {
    if (!std.mem.startsWith(u8, proto, "HTTP/")) return null;
    const version = proto[5..];
    const dot = std.mem.indexOfScalar(u8, version, '.') orelse return null;
    const major = std.fmt.parseInt(u8, version[0..dot], 10) catch return null;
    const minor = std.fmt.parseInt(u8, version[dot + 1 ..], 10) catch return null;
    return .{ .major = major, .minor = minor };
}

fn shouldCloseConnection(comptime std: type, headers: []const Header, major: u8, minor: u8) bool {
    const value = headerValue(headers, Header.connection) orelse return !(major == 1 and minor == 1);
    return std.ascii.eqlIgnoreCase(value, "close");
}

fn headerValue(headers: []const Header, name: []const u8) ?[]const u8 {
    for (headers) |hdr| {
        if (hdr.is(name)) return hdr.value;
    }
    return null;
}

fn writeBareResponse(comptime std: type, conn: Conn, status_code: u16, close_conn: bool) void {
    var local = conn;
    var head_buf: [128]u8 = undefined;
    const reason = status.text(status_code) orelse "Unknown";
    const head = std.fmt.bufPrint(
        &head_buf,
        "HTTP/1.1 {d} {s}\r\nContent-Length: 0\r\nConnection: {s}\r\n\r\n",
        .{ status_code, reason, if (close_conn) "close" else "keep-alive" },
    ) catch return;
    io.writeAll(@TypeOf(local), &local, head) catch {};
}

pub fn TestRunner(comptime std: type, comptime net: type) testing_api.TestRunner {
    return testing_api.TestRunner.fromFn(std, 3 * 1024 * 1024, struct {
        fn run(_: *testing_api.T, allocator: std.mem.Allocator) !void {
            const testing = std.testing;
            const S = Server(std, net);
            const Handler = handler_mod.Handler(std);
            const Writer = ResponseWriter(std);

            const Demo = struct {
                pub fn serveHTTP(_: *@This(), _: *Writer, _: *Request) void {}
            };

            var demo = Demo{};
            var server = try S.init(allocator, .{
                .handler = Handler.init(&demo),
            });
            defer server.deinit();

            try testing.expectError(error.NoDefaultHandler, server.handle("/x", Handler.init(&demo)));
        }
    }.run);
}
