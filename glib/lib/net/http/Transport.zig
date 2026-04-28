//! Transport — default concrete `http.RoundTripper`.
//!
//! This is the low-level HTTP/1.1 client transport, in the role of Go's
//! `http.Transport`. The current implementation supports:
//! direct HTTP over TCP, direct HTTPS over TLS, idle connection pooling,
//! request serialization, response parsing, and request-scoped timeout
//! application from `Request.context()`.

const std = @import("std");

const io = @import("io");
const dialer_mod = @import("../Dialer.zig");
const resolver_mod = @import("../Resolver.zig");
const tcp_conn_mod = @import("../TcpConn.zig");
const tls_mod = @import("../tls.zig");
const Conn = @import("../Conn.zig");
const Context = @import("context").Context;
const Header = @import("Header.zig");
const netip = @import("../netip.zig");
const ReadCloser = @import("ReadCloser.zig");
const Request = @import("Request.zig");
const Response = @import("Response.zig");
const RoundTripper = @import("RoundTripper.zig");
const textproto_reader_mod = @import("../textproto/Reader.zig");
const textproto_writer_mod = @import("../textproto/Writer.zig");
const url_mod = @import("../url.zig");
const proxy_authorization_value_limit = 32 * 1024;
const BufferedConnReader = io.BufferedReader(Conn);
const BufferedConnWriter = io.BufferedWriter(Conn);
const TextprotoReader = textproto_reader_mod.Reader(BufferedConnReader);
const TextprotoWriter = textproto_writer_mod.Writer(BufferedConnWriter);

pub fn Transport(comptime lib: type, comptime net: type) type {
    const Allocator = lib.mem.Allocator;
    const Addr = netip.AddrPort;
    const IpAddr = netip.Addr;
    const Dialer = dialer_mod.Dialer(lib, net);
    const Resolver = resolver_mod.Resolver(lib, net);
    const TcpConn = tcp_conn_mod.TcpConn(lib, net);
    const Tls = tls_mod.make(lib, net);
    const Thread = lib.Thread;
    const default_user_agent = "stdz-zig-http-client/1.0";
    const default_max_header_bytes = 32 * 1024;
    const unlimited_body_bytes = std.math.maxInt(usize);
    const default_body_io_buf_len = 1024;
    const max_informational_responses = 8;
    const default_http2_alpn = [_][]const u8{ "h2", "http/1.1" };
    const context_timeout_grace_ns = 5 * lib.time.ns_per_ms;
    return struct {
        allocator: Allocator,
        options: Options,
        resolver: Resolver,
        idle_mu: Thread.Mutex = .{},
        idle_conns: std.ArrayList(IdleConn),
        host_states: std.ArrayList(HostState),
        idle_generation: usize = 0,

        const Self = @This();

        pub const AlternateTransport = struct {
            ptr: *anyopaque,
            vtable: *const VTable,

            pub const VTable = struct {
                roundTrip: *const fn (ptr: *anyopaque, req: *const Request) RoundTripper.RoundTripError!Response,
                closeIdleConnections: *const fn (ptr: *anyopaque) void,
            };

            pub fn roundTrip(self: AlternateTransport, req: *const Request) RoundTripper.RoundTripError!Response {
                return self.vtable.roundTrip(self.ptr, req);
            }

            pub fn closeIdleConnections(self: AlternateTransport) void {
                self.vtable.closeIdleConnections(self.ptr);
            }

            pub fn init(pointer: anytype) AlternateTransport {
                const Ptr = @TypeOf(pointer);
                const info = @typeInfo(Ptr);
                if (info != .pointer or info.pointer.size != .one)
                    @compileError("AlternateTransport.init expects a single-item pointer");

                const Impl = info.pointer.child;
                const gen = struct {
                    fn roundTripFn(ptr: *anyopaque, req: *const Request) RoundTripper.RoundTripError!Response {
                        const self: *Impl = @ptrCast(@alignCast(ptr));
                        return self.roundTrip(req);
                    }

                    fn closeIdleConnectionsFn(ptr: *anyopaque) void {
                        const self: *Impl = @ptrCast(@alignCast(ptr));
                        self.closeIdleConnections();
                    }

                    const vtable = VTable{
                        .roundTrip = roundTripFn,
                        .closeIdleConnections = closeIdleConnectionsFn,
                    };
                };

                return .{
                    .ptr = pointer,
                    .vtable = &gen.vtable,
                };
            }
        };

        pub const AlternateProtocol = struct {
            protocol: []const u8,
            transport: AlternateTransport,
        };

        pub const ProxyConfig = struct {
            url: url_mod.Url,
            connect_headers: []const Header = &.{},
        };

        pub const Options = struct {
            dialer: Dialer.Options = .{},
            resolver: Resolver.Options = .{},
            spawn_config: Thread.SpawnConfig = .{},
            tls_client_config: ?Tls.Config = null,
            https_proxy: ?ProxyConfig = null,
            force_attempt_http2: bool = false,
            alternate_protocols: []const AlternateProtocol = &.{},
            user_agent: []const u8 = default_user_agent,
            body_io_buf_len: usize = default_body_io_buf_len,
            max_header_bytes: usize = default_max_header_bytes,
            max_body_bytes: usize = unlimited_body_bytes,
            tls_handshake_timeout_ms: ?u32 = 10 * 1000,
            response_header_timeout_ms: ?u32 = null,
            expect_continue_timeout_ms: u32 = 1000,
            disable_keep_alives: bool = false,
            max_conns_per_host: usize = 0,
            max_idle_conns: usize = 100,
            max_idle_conns_per_host: usize = 0,
            idle_conn_timeout_ms: ?u32 = 90 * 1000,
        };

        const IdleConn = struct {
            key: []u8,
            conn: Conn,
            idle_since_ms: i64,
        };

        const IdleConnTake = struct {
            key: []u8,
            conn: Conn,
            generation: usize,
        };

        const HostState = struct {
            key: []u8,
            live_conns: usize = 0,
            waiters: usize = 0,
            cond: Thread.Condition = .{},
        };

        const RouteInfo = struct {
            target_port: u16,
            dial_host: []const u8,
            dial_port: u16,
            proxy: ?ProxyConfig = null,
        };

        const ConnLease = struct {
            conn: ?Conn,
            pool_key: []u8 = &.{},
            pool_generation: usize = 0,
            reused: bool = false,
            reusable: bool = false,

            fn discard(self: *ConnLease, allocator: Allocator) void {
                if (self.conn) |owned_conn| owned_conn.deinit();
                if (self.pool_key.len != 0) allocator.free(self.pool_key);
                self.conn = null;
                self.pool_key = &.{};
            }
        };

        const BodyState = struct {
            allocator: Allocator,
            conn: Conn,
            buffered: BufferedConnReader,
            ctx: ?Context,
            mode: BodyMode = .none,
            max_header_bytes: usize = default_max_header_bytes,
            max_trailer_bytes: usize = default_max_header_bytes,
            max_body_bytes: usize,
            bytes_read: usize = 0,
            closed: bool = false,
            owns_conn: bool = false,
            request_body_state: ?*RequestBodyState = null,
            request_body_finished: bool = false,
            transport: ?*Self = null,
            pool_key: []u8 = &.{},
            pool_generation: usize = 0,
            reusable: bool = false,
            released_conn: bool = false,
            read_context_active: bool = false,

            const ChunkedState = struct {
                remaining_in_chunk: usize = 0,
                finished: bool = false,
            };

            const BodyMode = union(enum) {
                none,
                fixed: usize,
                eof,
                chunked: ChunkedState,
            };

            pub fn read(self: *BodyState, buf: []u8) anyerror!usize {
                if (self.closed or buf.len == 0) return 0;

                return switch (self.mode) {
                    .none => self.finishAndReturnEof(),
                    .fixed => |*remaining| self.readFixed(buf, remaining),
                    .eof => self.readFromStream(buf),
                    .chunked => |*chunked| self.readChunked(buf, chunked),
                };
            }

            pub fn close(self: *BodyState) void {
                if (self.closed) return;
                self.closed = true;
                self.abortRequestBody();
                // Wait for any request-body writer to stop before discarding the shared
                // connection; otherwise chunked/fixed body senders can race into BADF.
                self.finishRequestBody() catch {};
                self.clearReadContext();
                if (self.owns_conn) {
                    if (self.transport) |transport| {
                        transport.discardConn(self.conn, self.pool_key);
                        self.owns_conn = false;
                        self.released_conn = true;
                        self.pool_key = &.{};
                    } else {
                        self.conn.close();
                    }
                }
                self.freePoolKey();
            }

            pub fn deinit(self: *BodyState) void {
                self.close();
                self.buffered.deinit();
                if (self.owns_conn) self.conn.deinit();
                if (self.request_body_state) |writer| {
                    writer.destroy();
                    self.request_body_state = null;
                }
            }

            fn readFixed(self: *BodyState, buf: []u8, remaining: *usize) anyerror!usize {
                if (remaining.* == 0) return self.finishAndReturnEof();

                const n = self.readFromBuffered(buf[0..@min(buf.len, remaining.*)]) catch |err| return self.mapReadError(err);
                if (n == 0) return error.InvalidResponse;
                remaining.* -= n;
                return self.noteBytesRead(n);
            }

            fn readChunked(self: *BodyState, buf: []u8, chunked: *ChunkedState) anyerror!usize {
                if (chunked.finished) return self.finishAndReturnEof();

                if (chunked.remaining_in_chunk == 0) {
                    const chunk_size = try self.readNextChunkSize();
                    if (chunk_size == 0) {
                        try self.discardTrailers();
                        chunked.finished = true;
                        return self.finishAndReturnEof();
                    }
                    if (chunk_size > self.remainingBudget()) return error.BodyTooLarge;
                    chunked.remaining_in_chunk = chunk_size;
                }

                const n = try self.readFromStream(buf[0..@min(buf.len, chunked.remaining_in_chunk)]);
                if (n == 0) return error.InvalidResponse;

                chunked.remaining_in_chunk -= n;
                if (chunked.remaining_in_chunk == 0) {
                    self.expectBufferedCrlf() catch |err| return self.mapReadError(err);
                }
                return n;
            }

            fn readNextChunkSize(self: *BodyState) anyerror!usize {
                const line_buf = try self.allocator.alloc(u8, self.max_header_bytes);
                defer self.allocator.free(line_buf);
                const line = self.streamReadLine(line_buf) catch |err| return self.mapReadError(err);
                const semi = std.mem.indexOfScalar(u8, line, ';') orelse line.len;
                return std.fmt.parseInt(usize, std.mem.trim(u8, line[0..semi], " "), 16) catch error.InvalidResponse;
            }

            fn discardTrailers(self: *BodyState) anyerror!void {
                const line_buf = try self.allocator.alloc(u8, self.max_trailer_bytes);
                defer self.allocator.free(line_buf);
                while (true) {
                    const line = self.streamReadLine(line_buf) catch |err| return self.mapReadError(err);
                    if (line.len == 0) return;
                    if (line.len + 2 > self.max_trailer_bytes) return error.InvalidResponse;
                    self.max_trailer_bytes -= line.len + 2;
                }
            }

            fn readFromStream(self: *BodyState, buf: []u8) anyerror!usize {
                const remaining_budget = self.remainingBudget();
                if (remaining_budget == 0) {
                    var overflow_probe: [1]u8 = undefined;
                    const n = self.readFromBuffered(&overflow_probe) catch |err| switch (err) {
                        error.EndOfStream => return self.finishAndReturnEof(),
                        else => return self.mapReadError(err),
                    };
                    if (n == 0) return 0;
                    return error.BodyTooLarge;
                }

                const n = self.readFromBuffered(buf[0..@min(buf.len, remaining_budget)]) catch |err| switch (err) {
                    error.EndOfStream => return self.finishAndReturnEof(),
                    else => return self.mapReadError(err),
                };
                if (n == 0) return self.finishAndReturnEof();
                return self.noteBytesRead(n);
            }

            fn remainingBudget(self: *const BodyState) usize {
                return self.max_body_bytes -| self.bytes_read;
            }

            fn noteBytesRead(self: *BodyState, n: usize) anyerror!usize {
                if (n == 0) return 0;
                if (n > self.remainingBudget()) return error.BodyTooLarge;
                self.bytes_read += n;
                return n;
            }

            fn abortRequestBody(self: *BodyState) void {
                if (self.request_body_state) |writer| writer.requestAbort();
            }

            fn finishRequestBody(self: *BodyState) anyerror!void {
                if (self.request_body_finished) return;
                self.request_body_finished = true;
                if (self.request_body_state) |writer| {
                    if (writer.finish()) |err| return err;
                }
            }

            fn finishAndReturnEof(self: *BodyState) anyerror!usize {
                try self.finishRequestBody();
                self.returnConnToTransport();
                return 0;
            }

            fn returnConnToTransport(self: *BodyState) void {
                if (!self.reusable or self.released_conn or !self.owns_conn) return;
                const transport = self.transport orelse return;

                self.clearReadContext();
                transport.releaseConn(self.conn, self.pool_key, self.pool_generation);
                self.owns_conn = false;
                self.released_conn = true;
                self.pool_key = &.{};
            }

            fn freePoolKey(self: *BodyState) void {
                if (self.pool_key.len != 0) {
                    self.allocator.free(self.pool_key);
                    self.pool_key = &.{};
                }
            }

            fn streamRead(self: *BodyState, buf: []u8) anyerror!usize {
                return self.buffered.ioReader().readSliceShort(buf) catch |err| switch (err) {
                    error.ReadFailed => return self.buffered.err() orelse error.Unexpected,
                    else => return err,
                };
            }

            fn streamReadLine(self: *BodyState, buf: []u8) anyerror![]const u8 {
                const raw = self.buffered.ioReader().takeDelimiterInclusive('\n') catch |err| switch (err) {
                    error.ReadFailed => return self.buffered.err() orelse error.Unexpected,
                    else => return err,
                };
                if (raw.len < 2 or raw[raw.len - 2] != '\r') return error.InvalidResponse;
                const line = raw[0 .. raw.len - 2];
                if (line.len > buf.len) return error.BufferTooSmall;
                @memcpy(buf[0..line.len], line);
                return buf[0..line.len];
            }

            fn streamExpectCrlf(self: *BodyState) anyerror!void {
                if (try self.readBufferedByteNoContext() != '\r') return error.InvalidResponse;
                if (try self.readBufferedByteNoContext() != '\n') return error.InvalidResponse;
            }

            fn readFromBuffered(self: *BodyState, buf: []u8) anyerror!usize {
                return self.streamRead(buf);
            }

            fn expectBufferedCrlf(self: *BodyState) anyerror!void {
                return self.streamExpectCrlf();
            }

            fn readBufferedByteNoContext(self: *BodyState) anyerror!u8 {
                var one: [1]u8 = undefined;
                const n = self.buffered.ioReader().readSliceShort(&one) catch |err| switch (err) {
                    error.ReadFailed => return self.buffered.err() orelse error.Unexpected,
                    else => return err,
                };
                if (n == 0) return error.EndOfStream;
                return one[0];
            }

            fn clearReadContext(self: *BodyState) void {
                if (!self.read_context_active) return;
                self.read_context_active = false;
                if (self.conn.as(TcpConn)) |tcp_conn| {
                    tcp_conn.setReadContext(null) catch unreachable;
                    return;
                } else |_| {}
                if (self.conn.as(Tls.Conn)) |tls_conn| {
                    tls_conn.setReadContext(null) catch unreachable;
                } else |_| {}
            }

            fn contextTimeoutError(self: *BodyState) anyerror {
                if (self.ctx) |ctx| {
                    if (ctx.err()) |err| return err;
                    if (contextDeadlineExceeded(ctx)) return error.DeadlineExceeded;
                }
                return error.TimedOut;
            }

            fn mapReadError(self: *BodyState, err: anyerror) anyerror {
                return switch (err) {
                    error.EndOfStream => error.InvalidResponse,
                    error.BufferTooSmall => error.InvalidResponse,
                    error.TimedOut => self.contextTimeoutError(),
                    error.ConnectionReset => error.ConnectionReset,
                    error.ConnectionRefused => error.ConnectionRefused,
                    else => error.InvalidResponse,
                };
            }
        };

        const RequestBodyState = struct {
            allocator: Allocator,
            transport: *Self,
            conn: Conn,
            buffered: BufferedConnWriter,
            req: Request,
            body: ReadCloser,
            io_buf: []u8 = &.{},
            send_chunked: bool,
            content_length: usize,
            mu: Thread.Mutex = .{},
            continue_cond: Thread.Condition = .{},
            thread: ?Thread = null,
            body_closed: bool = false,
            abort_requested: bool = false,
            result: ?anyerror = null,
            continue_state: ContinueState = .send,
            expect_continue_timeout_ms: u32 = 0,
            write_context_active: bool = false,

            const ContinueState = enum {
                send,
                wait,
                skip,
            };

            fn spawn(
                allocator: Allocator,
                transport: *Self,
                conn: Conn,
                buffered: BufferedConnWriter,
                req: *const Request,
                body: ReadCloser,
                send_chunked: bool,
                content_length: usize,
                wait_for_continue: bool,
                expect_continue_timeout_ms: u32,
                write_context_active: bool,
            ) RoundTripper.RoundTripError!*RequestBodyState {
                const state = try allocator.create(RequestBodyState);
                errdefer allocator.destroy(state);

                const io_buf = try allocator.alloc(u8, transport.bodyIoBufLen(send_chunked, content_length));
                errdefer allocator.free(io_buf);

                state.* = .{
                    .allocator = allocator,
                    .transport = transport,
                    .conn = conn,
                    .buffered = buffered,
                    .req = req.*,
                    .body = body,
                    .io_buf = io_buf,
                    .send_chunked = send_chunked,
                    .content_length = content_length,
                    .continue_state = if (wait_for_continue and expect_continue_timeout_ms != 0) .wait else .send,
                    .expect_continue_timeout_ms = expect_continue_timeout_ms,
                    .write_context_active = write_context_active,
                };
                state.thread = Thread.spawn(transport.options.spawn_config, run, .{state}) catch {
                    state.closeBody();
                    state.freeIoBuf();
                    return error.Unexpected;
                };
                return state;
            }

            fn requestAbort(self: *RequestBodyState) void {
                self.mu.lock();
                self.abort_requested = true;
                if (self.continue_state == .wait) {
                    self.continue_state = .skip;
                    self.continue_cond.broadcast();
                }
                self.mu.unlock();
                self.closeBody();
                self.conn.close();
            }

            fn closeBody(self: *RequestBodyState) void {
                self.mu.lock();
                const should_close = !self.body_closed;
                if (should_close) self.body_closed = true;
                self.mu.unlock();
                if (should_close) self.body.close();
            }

            fn finish(self: *RequestBodyState) ?anyerror {
                const thread = self.takeThread() orelse {
                    self.clearWriteContext();
                    self.mu.lock();
                    defer self.mu.unlock();
                    return self.result;
                };
                thread.join();
                self.clearWriteContext();
                self.mu.lock();
                defer self.mu.unlock();
                return self.result;
            }

            fn destroy(self: *RequestBodyState) void {
                self.freeIoBuf();
                self.buffered.deinit();
                self.allocator.destroy(self);
            }

            fn freeIoBuf(self: *RequestBodyState) void {
                self.allocator.free(self.io_buf);
                self.io_buf = &.{};
            }

            fn clearWriteContext(self: *RequestBodyState) void {
                if (!self.write_context_active) return;
                self.write_context_active = false;
                if (self.conn.as(TcpConn)) |tcp_conn| {
                    tcp_conn.setWriteContext(null) catch unreachable;
                    return;
                } else |_| {}
                if (self.conn.as(Tls.Conn)) |tls_conn| {
                    tls_conn.setWriteContext(null) catch unreachable;
                } else |_| {}
            }

            fn takeThread(self: *RequestBodyState) ?Thread {
                self.mu.lock();
                defer self.mu.unlock();
                const thread = self.thread;
                self.thread = null;
                return thread;
            }

            fn recordResult(self: *RequestBodyState, err: anyerror) void {
                self.mu.lock();
                defer self.mu.unlock();
                if (!self.abort_requested) self.result = err;
            }

            fn allowBodySend(self: *RequestBodyState) void {
                self.mu.lock();
                defer self.mu.unlock();
                if (self.continue_state == .wait) {
                    self.continue_state = .send;
                    self.continue_cond.broadcast();
                }
            }

            fn skipBodySend(self: *RequestBodyState) void {
                self.mu.lock();
                defer self.mu.unlock();
                if (self.continue_state == .wait) {
                    self.continue_state = .skip;
                    self.continue_cond.broadcast();
                }
            }

            fn isWaitingForContinue(self: *RequestBodyState) bool {
                self.mu.lock();
                defer self.mu.unlock();
                return self.continue_state == .wait;
            }

            fn waitForBodySend(self: *RequestBodyState) bool {
                self.mu.lock();
                defer self.mu.unlock();

                if (self.continue_state != .wait) return self.continue_state != .skip and !self.abort_requested;

                const wait_quantum_ns = 5 * lib.time.ns_per_ms;
                const continue_deadline_ns = lib.time.nanoTimestamp() +
                    @as(i128, self.expect_continue_timeout_ms) * lib.time.ns_per_ms;

                while (self.continue_state == .wait and !self.abort_requested) {
                    if (self.req.context()) |ctx| {
                        if (ctx.err()) |err| {
                            self.continue_state = .skip;
                            self.result = err;
                            return false;
                        }
                    }

                    const now_ns = lib.time.nanoTimestamp();
                    if (now_ns >= continue_deadline_ns) {
                        self.continue_state = .send;
                        break;
                    }

                    var wait_ns: i128 = @min(continue_deadline_ns - now_ns, wait_quantum_ns);
                    if (self.req.context()) |ctx| {
                        if (ctx.deadline()) |ctx_deadline_ns| {
                            const ctx_remaining_ns = ctx_deadline_ns - now_ns;
                            if (ctx_remaining_ns <= 0) {
                                self.continue_state = .skip;
                                self.result = error.DeadlineExceeded;
                                return false;
                            }
                            wait_ns = @min(wait_ns, ctx_remaining_ns);
                        }
                    }

                    self.continue_cond.timedWait(&self.mu, @intCast(@max(wait_ns, 1))) catch |err| switch (err) {
                        error.Timeout => {},
                    };
                }

                return self.continue_state != .skip and !self.abort_requested;
            }

            fn run(self: *RequestBodyState) void {
                defer self.closeBody();
                const should_send = self.waitForBodySend();
                if (!should_send) return;
                if (self.send_chunked) {
                    self.transport.writeChunkedBody(&self.buffered, self.conn, &self.req, self.body, self.io_buf, true) catch |err| {
                        self.recordResult(err);
                        return;
                    };
                    self.transport.flushBufferedWriter(&self.buffered, self.conn, &self.req) catch |err| {
                        self.recordResult(err);
                    };
                    return;
                }

                self.transport.writeFixedBody(&self.buffered, self.conn, &self.req, self.body, self.content_length, self.io_buf, true) catch |err| {
                    self.recordResult(err);
                    return;
                };
                self.transport.flushBufferedWriter(&self.buffered, self.conn, &self.req) catch |err| {
                    self.recordResult(err);
                };
            }
        };

        const ResponseState = struct {
            allocator: Allocator,
            head_storage: []u8,
            headers: []Header,
            body_state: ?*BodyState = null,
            tls_state: ?Tls.Conn.ConnectionState = null,
        };

        const ParsedHead = struct {
            status: []const u8,
            status_code: u16,
            proto: []const u8,
            proto_major: u8,
            proto_minor: u8,
            headers: []Header,
            content_length: ?usize = null,
            chunked: bool = false,
            close: bool = false,
            keep_alive: bool = false,
        };

        pub fn init(allocator: Allocator, options: Options) Allocator.Error!Self {
            var owned_options = options;
            if (owned_options.body_io_buf_len == 0) owned_options.body_io_buf_len = default_body_io_buf_len;
            if (owned_options.max_header_bytes == 0) owned_options.max_header_bytes = default_max_header_bytes;
            if (owned_options.max_body_bytes == 0) owned_options.max_body_bytes = unlimited_body_bytes;
            return .{
                .allocator = allocator,
                .options = owned_options,
                .resolver = try Resolver.init(allocator, owned_options.resolver),
                .idle_conns = try std.ArrayList(IdleConn).initCapacity(allocator, 0),
                .host_states = try std.ArrayList(HostState).initCapacity(allocator, 0),
            };
        }

        pub fn deinit(self: *Self) void {
            self.closeIdleConnections();
            self.idle_conns.deinit(self.allocator);
            for (self.host_states.items) |state| {
                self.allocator.free(state.key);
            }
            self.host_states.deinit(self.allocator);
            self.resolver.deinit();
            self.* = undefined;
        }

        pub fn closeIdleConnections(self: *Self) void {
            self.idle_mu.lock();
            self.idle_generation += 1;
            while (self.idle_conns.items.len != 0) {
                const idle = self.idle_conns.orderedRemove(self.idle_conns.items.len - 1);
                self.closeIdleConn(idle);
            }
            self.idle_mu.unlock();

            for (self.options.alternate_protocols) |alt| {
                alt.transport.closeIdleConnections();
            }
        }

        pub fn roundTripper(self: *Self) RoundTripper {
            return RoundTripper.init(self);
        }

        pub fn roundTrip(self: *Self, req: *const Request) RoundTripper.RoundTripError!Response {
            if (req.context()) |ctx| {
                if (ctx.err()) |err| return err;
            }
            try self.validateRequest(req);
            if (std.ascii.eqlIgnoreCase(req.effectiveMethod(), "CONNECT")) return error.UnsupportedMethod;
            var attempt_req = req.*;
            var retried = false;

            while (true) {
                var reused = false;
                const resp = self.roundTripAttempt(&attempt_req, &reused) catch |err| {
                    if (!retried and self.shouldRetryRequest(&attempt_req, reused, err)) {
                        attempt_req = try rewindRequest(&attempt_req);
                        retried = true;
                        continue;
                    }
                    return err;
                };
                return resp;
            }
        }

        fn roundTripAttempt(self: *Self, req: *const Request, reused: *bool) RoundTripper.RoundTripError!Response {
            var lease = try self.acquireConn(req);
            defer self.discardLease(&lease);
            reused.* = lease.reused;

            if (try self.roundTripAlternateIfNeeded(&lease, req)) |resp| return resp;

            var request_body_state: ?*RequestBodyState = null;
            const send_chunked = self.shouldSendChunkedRequest(req);
            const wait_for_continue = self.shouldWaitForContinue(req);
            const content_length: usize = if (req.content_length > 0)
                @intCast(req.content_length)
            else
                0;
            errdefer if (request_body_state == null) {
                if (req.body()) |body| body.close();
            };

            try self.applyTimeouts(lease.conn.?, req);
            var conn_writer = lease.conn.?;
            var write_ctx_active = try self.setConnWriteContext(conn_writer, req.context());
            defer self.clearConnWriteContext(conn_writer, write_ctx_active);
            var buffered_writer = try BufferedConnWriter.initAlloc(&conn_writer, req.allocator, self.options.body_io_buf_len);
            var buffered_writer_transferred = false;
            defer if (!buffered_writer_transferred) buffered_writer.deinit();

            try self.writeRequestHead(&buffered_writer, conn_writer, req);
            try self.flushBufferedWriter(&buffered_writer, conn_writer, req);

            defer if (request_body_state) |state| {
                state.requestAbort();
                _ = state.finish();
                state.destroy();
            };

            if (req.body()) |body| {
                request_body_state = try RequestBodyState.spawn(
                    req.allocator,
                    self,
                    conn_writer,
                    buffered_writer,
                    req,
                    body,
                    send_chunked,
                    content_length,
                    wait_for_continue,
                    self.options.expect_continue_timeout_ms,
                    write_ctx_active,
                );
                write_ctx_active = false;
                buffered_writer_transferred = true;
            }

            try self.applyResponseHeaderReadTimeout(lease.conn.?, req);
            return self.readResponseWithWriter(&lease, req, &request_body_state);
        }

        fn acquireConn(self: *Self, req: *const Request) RoundTripper.RoundTripError!ConnLease {
            const route = try self.requestRoute(req);
            if (self.maxConnsPerHost()) |_| {
                return self.acquireConnWithLimit(req, route);
            }
            if (!self.shouldAttemptConnectionReuse(req)) {
                const addr = try self.resolve(req, route.dial_host, route.dial_port);
                return .{ .conn = try self.dialRoute(req, route, addr) };
            }

            const pool_key = try self.connectionPoolKeyForRoute(req, route);
            errdefer self.allocator.free(pool_key);

            if (self.takeIdleConn(pool_key)) |taken| {
                self.allocator.free(pool_key);
                return .{
                    .conn = taken.conn,
                    .pool_key = taken.key,
                    .pool_generation = taken.generation,
                    .reused = true,
                    .reusable = true,
                };
            }

            const addr = try self.resolve(req, route.dial_host, route.dial_port);
            return .{
                .conn = try self.dialRoute(req, route, addr),
                .pool_key = pool_key,
                .pool_generation = self.currentIdleGeneration(),
                .reusable = true,
            };
        }

        fn acquireConnWithLimit(self: *Self, req: *const Request, route: RouteInfo) RoundTripper.RoundTripError!ConnLease {
            const can_reuse = self.shouldAttemptConnectionReuse(req);
            const cap = self.maxConnsPerHost() orelse unreachable;
            const pool_key = try self.connectionPoolKeyForRoute(req, route);
            errdefer self.allocator.free(pool_key);

            while (true) {
                self.idle_mu.lock();
                self.pruneExpiredIdleLocked();

                if (can_reuse) {
                    if (self.takeIdleConnLocked(pool_key)) |taken| {
                        self.idle_mu.unlock();
                        self.allocator.free(pool_key);
                        return .{
                            .conn = taken.conn,
                            .pool_key = taken.key,
                            .pool_generation = taken.generation,
                            .reused = true,
                            .reusable = true,
                        };
                    }
                }

                const host_state = try self.getOrCreateHostStateLocked(pool_key);
                if (host_state.live_conns < cap) {
                    host_state.live_conns += 1;
                    const pool_generation = self.idle_generation;
                    self.idle_mu.unlock();

                    const addr = self.resolve(req, route.dial_host, route.dial_port) catch |err| {
                        self.idle_mu.lock();
                        self.noteConnClosedLocked(pool_key);
                        self.idle_mu.unlock();
                        return err;
                    };
                    const conn = self.dialRoute(req, route, addr) catch |err| {
                        self.idle_mu.lock();
                        self.noteConnClosedLocked(pool_key);
                        self.idle_mu.unlock();
                        return err;
                    };

                    return .{
                        .conn = conn,
                        .pool_key = pool_key,
                        .pool_generation = pool_generation,
                        .reused = false,
                        .reusable = can_reuse,
                    };
                }

                host_state.waiters += 1;
                self.waitForConnAvailableLocked(req, host_state) catch |err| {
                    host_state.waiters -= 1;
                    self.idle_mu.unlock();
                    return err;
                };
                host_state.waiters -= 1;
                self.idle_mu.unlock();
            }
        }

        fn resolve(self: *Self, req: *const Request, host: []const u8, port: u16) RoundTripper.RoundTripError!Addr {
            if (IpAddr.parse(host)) |ip| return Addr.init(ip, port) else |_| {}

            var addrs: [8]IpAddr = undefined;
            const count = (if (req.context()) |ctx|
                self.resolver.lookupHostContext(ctx, host, &addrs)
            else
                self.resolver.lookupHost(host, &addrs)) catch |err| return switch (err) {
                error.NameNotFound => error.NameNotResolved,
                error.Timeout => error.TimedOut,
                error.DeadlineExceeded, error.Canceled => err,
                else => error.Unexpected,
            };
            if (count == 0) return error.NameNotResolved;

            return Addr.init(addrs[0], port);
        }

        fn dialRoute(self: *Self, req: *const Request, route: RouteInfo, addr: Addr) RoundTripper.RoundTripError!Conn {
            if (route.proxy != null) return self.dialHttpsViaProxy(req, route, addr);
            if (std.mem.eql(u8, req.url.scheme, "http")) return self.dialTcp(req, addr);
            if (std.mem.eql(u8, req.url.scheme, "https")) return self.dialHttps(req, addr);
            return error.UnsupportedScheme;
        }

        fn dialTcp(self: *Self, req: *const Request, addr: Addr) RoundTripper.RoundTripError!Conn {
            var d = Dialer.init(self.allocator, self.options.dialer);
            const conn = if (req.context()) |ctx|
                d.dialContext(ctx, .tcp, addr)
            else
                d.dial(.tcp, addr);
            return conn catch |err| return switch (err) {
                error.ConnectionRefused => error.ConnectionRefused,
                error.DeadlineExceeded, error.Canceled => err,
                error.ConnectionTimedOut, error.WouldBlock => self.contextTimeoutError(req),
                error.OutOfMemory => error.OutOfMemory,
                else => error.Unexpected,
            };
        }

        fn dialHttps(self: *Self, req: *const Request, addr: Addr) RoundTripper.RoundTripError!Conn {
            var tls_dialer = Tls.Dialer.init(
                Dialer.init(self.allocator, self.options.dialer),
                self.tlsClientConfig(req),
            );
            var tls_conn = (if (req.context()) |ctx|
                tls_dialer.dialContext(ctx, .tcp, addr)
            else
                tls_dialer.dial(.tcp, addr)) catch |err| return switch (err) {
                error.ConnectionRefused => error.ConnectionRefused,
                error.DeadlineExceeded, error.Canceled => err,
                error.ConnectionTimedOut, error.WouldBlock => self.contextTimeoutError(req),
                error.OutOfMemory => error.OutOfMemory,
                else => error.Unexpected,
            };
            errdefer tls_conn.deinit();

            const handshake_timeout_ms = try self.tlsHandshakeTimeout(req);
            tls_conn.setReadTimeout(handshake_timeout_ms);
            tls_conn.setWriteTimeout(handshake_timeout_ms);

            const handshake_started_ms = lib.time.milliTimestamp();
            const typed = tls_conn.as(Tls.Conn) catch return error.Unexpected;
            const handshake_read_ctx_active = try self.setConnReadContext(tls_conn, req.context());
            defer self.clearConnReadContext(tls_conn, handshake_read_ctx_active);
            const handshake_write_ctx_active = try self.setConnWriteContext(tls_conn, req.context());
            defer self.clearConnWriteContext(tls_conn, handshake_write_ctx_active);
            typed.handshake() catch |err| return switch (err) {
                error.RecordIoFailed => self.mapTlsHandshakeIoError(req, handshake_timeout_ms, handshake_started_ms),
                else => err,
            };

            return tls_conn;
        }

        fn dialHttpsViaProxy(self: *Self, req: *const Request, route: RouteInfo, proxy_addr: Addr) RoundTripper.RoundTripError!Conn {
            const proxy = route.proxy orelse return error.Unexpected;
            var proxy_conn = try self.dialTcp(req, proxy_addr);
            {
                errdefer proxy_conn.deinit();
                try self.applyTimeouts(proxy_conn, req);
                var proxy_conn_writer = proxy_conn;
                const write_ctx_active = try self.setConnWriteContext(proxy_conn_writer, req.context());
                defer self.clearConnWriteContext(proxy_conn_writer, write_ctx_active);
                var buffered_writer = try BufferedConnWriter.initAlloc(&proxy_conn_writer, req.allocator, self.options.body_io_buf_len);
                defer buffered_writer.deinit();
                try self.writeConnectRequest(&buffered_writer, proxy_conn_writer, req, proxy, route.target_port);
                try self.flushBufferedWriter(&buffered_writer, proxy_conn_writer, req);
                try self.applyResponseHeaderReadTimeout(proxy_conn, req);
                try self.readConnectResponse(proxy_conn, req);
            }

            var tls_conn = blk: {
                errdefer proxy_conn.deinit();
                break :blk Tls.Conn.init(self.allocator, proxy_conn, self.tlsClientConfig(req)) catch |err| return switch (err) {
                    error.OutOfMemory => error.OutOfMemory,
                    else => error.Unexpected,
                };
            };
            errdefer tls_conn.deinit();

            const handshake_timeout_ms = try self.tlsHandshakeTimeout(req);
            tls_conn.setReadTimeout(handshake_timeout_ms);
            tls_conn.setWriteTimeout(handshake_timeout_ms);

            const handshake_started_ms = lib.time.milliTimestamp();
            const typed = tls_conn.as(Tls.Conn) catch return error.Unexpected;
            const handshake_read_ctx_active = try self.setConnReadContext(tls_conn, req.context());
            defer self.clearConnReadContext(tls_conn, handshake_read_ctx_active);
            const handshake_write_ctx_active = try self.setConnWriteContext(tls_conn, req.context());
            defer self.clearConnWriteContext(tls_conn, handshake_write_ctx_active);
            typed.handshake() catch |err| return switch (err) {
                error.RecordIoFailed => self.mapTlsHandshakeIoError(req, handshake_timeout_ms, handshake_started_ms),
                else => err,
            };

            return tls_conn;
        }

        fn applyTimeouts(self: *Self, conn: Conn, req: *const Request) RoundTripper.RoundTripError!void {
            const remaining = try self.contextDeadlineTimeout(req);
            conn.setReadTimeout(remaining);
            conn.setWriteTimeout(remaining);
        }

        fn setConnReadContext(self: *Self, conn: Conn, ctx: ?Context) RoundTripper.RoundTripError!bool {
            _ = self;
            const active_ctx = ctx orelse return false;
            if (conn.as(TcpConn)) |tcp_conn| {
                try tcp_conn.setReadContext(active_ctx);
                return true;
            } else |_| {}
            if (conn.as(Tls.Conn)) |tls_conn| {
                try tls_conn.setReadContext(active_ctx);
                return true;
            } else |_| {}
            return false;
        }

        fn clearConnReadContext(self: *Self, conn: Conn, active: bool) void {
            _ = self;
            if (!active) return;
            if (conn.as(TcpConn)) |tcp_conn| {
                tcp_conn.setReadContext(null) catch unreachable;
                return;
            } else |_| {}
            if (conn.as(Tls.Conn)) |tls_conn| {
                tls_conn.setReadContext(null) catch unreachable;
            } else |_| {}
        }

        fn setConnWriteContext(self: *Self, conn: Conn, ctx: ?Context) RoundTripper.RoundTripError!bool {
            _ = self;
            const active_ctx = ctx orelse return false;
            if (conn.as(TcpConn)) |tcp_conn| {
                try tcp_conn.setWriteContext(active_ctx);
                return true;
            } else |_| {}
            if (conn.as(Tls.Conn)) |tls_conn| {
                try tls_conn.setWriteContext(active_ctx);
                return true;
            } else |_| {}
            return false;
        }

        fn clearConnWriteContext(self: *Self, conn: Conn, active: bool) void {
            _ = self;
            if (!active) return;
            if (conn.as(TcpConn)) |tcp_conn| {
                tcp_conn.setWriteContext(null) catch unreachable;
                return;
            } else |_| {}
            if (conn.as(Tls.Conn)) |tls_conn| {
                tls_conn.setWriteContext(null) catch unreachable;
            } else |_| {}
        }

        fn applyResponseHeaderReadTimeout(self: *Self, conn: Conn, req: *const Request) RoundTripper.RoundTripError!void {
            conn.setReadTimeout(try self.responseHeaderTimeout(req));
        }

        fn restoreResponseBodyReadTimeout(self: *Self, conn: Conn, req: *const Request) RoundTripper.RoundTripError!void {
            conn.setReadTimeout(try self.contextDeadlineTimeout(req));
        }

        fn contextDeadlineTimeout(self: *Self, req: *const Request) RoundTripper.RoundTripError!?u32 {
            _ = self;
            const ctx = req.context() orelse return null;
            const deadline = ctx.deadline() orelse return null;

            const remaining_ns = deadline - lib.time.nanoTimestamp();
            if (remaining_ns <= 0) return error.DeadlineExceeded;

            const remaining_ms = @divFloor(remaining_ns, lib.time.ns_per_ms) + @intFromBool(@mod(remaining_ns, lib.time.ns_per_ms) != 0);
            return if (remaining_ms > std.math.maxInt(u32))
                std.math.maxInt(u32)
            else
                @intCast(remaining_ms);
        }

        fn responseHeaderTimeout(self: *Self, req: *const Request) RoundTripper.RoundTripError!?u32 {
            return minTimeoutMs(
                try self.contextDeadlineTimeout(req),
                self.options.response_header_timeout_ms,
            );
        }

        fn tlsHandshakeTimeout(self: *Self, req: *const Request) RoundTripper.RoundTripError!?u32 {
            return minTimeoutMs(
                try self.contextDeadlineTimeout(req),
                self.options.tls_handshake_timeout_ms,
            );
        }

        fn tlsClientConfig(self: *Self, req: *const Request) Tls.Config {
            var config = self.options.tls_client_config orelse Tls.Config{ .server_name = req.url.host };
            if (config.server_name.len == 0) config.server_name = req.url.host;
            if (config.alpn_protocols.len == 0 and self.options.force_attempt_http2) {
                config.alpn_protocols = &default_http2_alpn;
            }
            return config;
        }

        fn roundTripAlternateIfNeeded(self: *Self, lease: *ConnLease, req: *const Request) RoundTripper.RoundTripError!?Response {
            const conn = lease.conn orelse return null;
            const alt = try self.alternateTransportForConn(req, conn) orelse return null;
            const owned_conn = lease.conn.?;
            const pool_key = lease.pool_key;
            lease.conn = null;
            lease.pool_key = &.{};
            self.discardConn(owned_conn, pool_key);
            return @as(?Response, try alt.roundTrip(req));
        }

        fn alternateTransportForConn(self: *Self, req: *const Request, conn: Conn) RoundTripper.RoundTripError!?AlternateTransport {
            if (!std.mem.eql(u8, req.url.scheme, "https")) return null;
            const tls_conn = conn.as(Tls.Conn) catch |err| return switch (err) {
                error.TypeMismatch => null,
            };
            const negotiated = tls_conn.negotiatedProtocol() catch return error.Unexpected;
            const protocol = negotiated orelse return null;
            if (std.mem.eql(u8, protocol, "http/1.1")) return null;
            return self.findAlternateProtocol(protocol) orelse error.UnsupportedProtocol;
        }

        fn findAlternateProtocol(self: *Self, protocol: []const u8) ?AlternateTransport {
            for (self.options.alternate_protocols) |alt| {
                if (std.mem.eql(u8, alt.protocol, protocol)) return alt.transport;
            }
            return null;
        }

        fn mapTlsHandshakeIoError(self: *Self, req: *const Request, handshake_timeout_ms: ?u32, started_ms: i64) RoundTripper.RoundTripError {
            _ = self;
            if (req.context()) |ctx| {
                if (ctx.err()) |err| return err;
                if (ctx.deadline()) |deadline| {
                    if (lib.time.nanoTimestamp() >= deadline) return error.DeadlineExceeded;
                }
            }
            if (handshake_timeout_ms) |timeout_ms| {
                if (lib.time.milliTimestamp() - started_ms >= @as(i64, timeout_ms)) return error.TimedOut;
            }
            return error.Unexpected;
        }

        fn writeRequest(self: *Self, conn: Conn, req: *const Request) RoundTripper.RoundTripError!void {
            var conn_writer = conn;
            const write_ctx_active = try self.setConnWriteContext(conn_writer, req.context());
            defer self.clearConnWriteContext(conn_writer, write_ctx_active);
            var buffered_writer = try BufferedConnWriter.initAlloc(&conn_writer, req.allocator, self.options.body_io_buf_len);
            defer buffered_writer.deinit();
            try self.writeRequestHead(&buffered_writer, conn_writer, req);

            if (req.body()) |read_closer| {
                defer read_closer.close();

                const send_chunked = self.shouldSendChunkedRequest(req);
                const content_length: usize = if (!send_chunked and req.content_length > 0)
                    @intCast(req.content_length)
                else
                    0;
                const io_buf = try self.allocator.alloc(u8, self.bodyIoBufLen(send_chunked, content_length));
                defer self.allocator.free(io_buf);

                if (send_chunked) {
                    try self.writeChunkedBody(&buffered_writer, conn_writer, req, read_closer, io_buf, false);
                } else {
                    try self.writeFixedBody(&buffered_writer, conn_writer, req, read_closer, content_length, io_buf, false);
                }
            }
            try self.flushBufferedWriter(&buffered_writer, conn_writer, req);
        }

        fn writeRequestHead(self: *Self, buffered: *BufferedConnWriter, conn: Conn, req: *const Request) RoundTripper.RoundTripError!void {
            const allocator = req.allocator;
            const target = try self.requestTarget(allocator, req);
            defer allocator.free(target);

            const host_value = try self.hostHeaderValue(allocator, req);
            defer allocator.free(host_value);

            const method = req.effectiveMethod();
            const body = req.body();
            const send_chunked = body != null and self.shouldSendChunkedRequest(req);
            const content_length: usize = if (req.content_length > 0)
                @intCast(req.content_length)
            else
                0;
            const wants_close = self.requestWantsClose(req) or self.options.disable_keep_alives;

            try self.validateRequestBodyLimit(req);
            if (req.trailer.len != 0) return error.UnsupportedTrailers;

            var writer = TextprotoWriter.fromBuffered(buffered);
            try self.writeTextprotoLine(&writer, buffered, conn, req, &.{ method, " ", target, " ", req.proto });

            var has_host = false;
            var has_connection = false;
            var has_content_length = false;
            var has_transfer_encoding = false;
            var saw_user_agent = false;
            var user_agent_value: ?[]const u8 = null;

            for (req.header) |hdr| {
                if (hdr.is(Header.host)) has_host = true;
                if (hdr.is(Header.connection)) has_connection = true;
                if (hdr.is(Header.content_length)) has_content_length = true;
                if (hdr.is(Header.transfer_encoding)) has_transfer_encoding = true;
                if (hdr.is(Header.user_agent)) {
                    if (!saw_user_agent) {
                        saw_user_agent = true;
                        user_agent_value = hdr.value;
                    }
                    continue;
                }

                try self.writeTextprotoLine(&writer, buffered, conn, req, &.{ hdr.name, ": ", hdr.value });
            }

            if (!has_host) try self.writeTextprotoLine(&writer, buffered, conn, req, &.{ Header.host, ": ", host_value });
            if (!has_connection and wants_close) try self.writeTextprotoLine(&writer, buffered, conn, req, &.{ Header.connection, ": ", "close" });
            if (!saw_user_agent) {
                if (self.options.user_agent.len != 0) {
                    try self.writeTextprotoLine(&writer, buffered, conn, req, &.{ Header.user_agent, ": ", self.options.user_agent });
                }
            } else if (user_agent_value) |value| {
                if (value.len != 0) try self.writeTextprotoLine(&writer, buffered, conn, req, &.{ Header.user_agent, ": ", value });
            }
            if (send_chunked and !has_transfer_encoding) {
                try self.writeTextprotoLine(&writer, buffered, conn, req, &.{ Header.transfer_encoding, ": ", "chunked" });
            } else if (!has_content_length and (body != null or req.content_length > 0)) {
                const len_buf = try std.fmt.allocPrint(allocator, "{d}", .{content_length});
                defer allocator.free(len_buf);
                try self.writeTextprotoLine(&writer, buffered, conn, req, &.{ Header.content_length, ": ", len_buf });
            }

            try self.writeTextprotoLine(&writer, buffered, conn, req, &.{});
        }

        fn writeAllBuffered(self: *Self, buffered: *BufferedConnWriter, conn: Conn, req: *const Request, buf: []const u8) RoundTripper.RoundTripError!void {
            _ = conn;
            buffered.ioWriter().writeAll(buf) catch return self.mapBufferedWriteError(buffered, req);
        }

        fn flushBufferedWriter(self: *Self, buffered: *BufferedConnWriter, conn: Conn, req: *const Request) RoundTripper.RoundTripError!void {
            _ = conn;
            buffered.flush() catch return self.mapBufferedWriteError(buffered, req);
        }

        fn mapBufferedWriteError(self: *Self, buffered: *BufferedConnWriter, req: *const Request) RoundTripper.RoundTripError {
            return self.mapWriteError(buffered.err() orelse error.Unexpected, req);
        }

        fn writeTextprotoLine(
            self: *Self,
            writer: *TextprotoWriter,
            buffered: *BufferedConnWriter,
            conn: Conn,
            req: *const Request,
            parts: []const []const u8,
        ) RoundTripper.RoundTripError!void {
            _ = conn;
            writer.writeLineParts(parts) catch |err| switch (err) {
                error.InvalidLine => return error.InvalidHeader,
                error.WriteFailed => return self.mapBufferedWriteError(buffered, req),
            };
        }

        fn shouldSendChunkedRequest(_: *Self, req: *const Request) bool {
            if (req.transfer_encoding.len != 0) {
                for (req.transfer_encoding) |encoding| {
                    if (std.ascii.eqlIgnoreCase(encoding, "chunked")) return true;
                }
            }
            return req.content_length <= 0;
        }

        fn bodyIoBufLen(self: *Self, send_chunked: bool, content_length: usize) usize {
            if (send_chunked) return self.options.body_io_buf_len;
            return @min(self.options.body_io_buf_len, content_length);
        }

        fn writeFixedBody(
            self: *Self,
            buffered: *BufferedConnWriter,
            conn: Conn,
            req: *const Request,
            body: ReadCloser,
            content_length: usize,
            buf: []u8,
            flush_each_chunk: bool,
        ) RoundTripper.RoundTripError!void {
            if (content_length > self.options.max_body_bytes) return error.BodyTooLarge;
            if (content_length == 0) return;
            if (buf.len == 0) return error.Unexpected;

            var remaining = content_length;
            var reader = body;
            while (remaining != 0) {
                try self.checkRequestSendContext(req);
                const n = try reader.read(buf[0..@min(buf.len, remaining)]);
                if (n == 0) return error.InvalidResponse;
                try self.checkRequestSendContext(req);
                try self.writeAllBuffered(buffered, conn, req, buf[0..n]);
                if (flush_each_chunk) {
                    try self.flushBufferedWriter(buffered, conn, req);
                    try self.checkRequestSendContext(req);
                }
                remaining -= n;
            }
        }

        fn writeChunkedBody(
            self: *Self,
            buffered: *BufferedConnWriter,
            conn: Conn,
            req: *const Request,
            body: ReadCloser,
            buf: []u8,
            flush_each_chunk: bool,
        ) RoundTripper.RoundTripError!void {
            if (buf.len == 0) return error.Unexpected;

            var reader = body;
            var size_buf: [32]u8 = undefined;
            var total_written: usize = 0;

            while (true) {
                try self.checkRequestSendContext(req);
                const n = try reader.read(buf);
                if (n == 0) break;
                if (n > self.options.max_body_bytes -| total_written) return error.BodyTooLarge;
                total_written += n;
                try self.checkRequestSendContext(req);

                const size_line = std.fmt.bufPrint(&size_buf, "{x}\r\n", .{n}) catch return error.Unexpected;
                try self.writeAllBuffered(buffered, conn, req, size_line);
                try self.writeAllBuffered(buffered, conn, req, buf[0..n]);
                try self.writeAllBuffered(buffered, conn, req, "\r\n");
                if (flush_each_chunk) {
                    try self.flushBufferedWriter(buffered, conn, req);
                    try self.checkRequestSendContext(req);
                }
            }

            try self.checkRequestSendContext(req);
            try self.writeAllBuffered(buffered, conn, req, "0\r\n\r\n");
            if (flush_each_chunk) {
                try self.flushBufferedWriter(buffered, conn, req);
                try self.checkRequestSendContext(req);
            }
        }

        fn requestTarget(_: *Self, allocator: Allocator, req: *const Request) Allocator.Error![]u8 {
            if (req.request_uri.len != 0) return allocator.dupe(u8, req.request_uri);

            const path = if (req.url.path.len != 0) req.url.path else "/";
            if (req.url.raw_query.len == 0) return allocator.dupe(u8, path);
            return std.fmt.allocPrint(allocator, "{s}?{s}", .{ path, req.url.raw_query });
        }

        fn hostHeaderValue(_: *Self, allocator: Allocator, req: *const Request) Allocator.Error![]u8 {
            if (req.host.len != 0) return allocator.dupe(u8, req.host);

            const host = req.url.host;
            const needs_brackets = std.mem.indexOfScalar(u8, host, ':') != null;
            if (req.url.port.len == 0) {
                if (needs_brackets) return std.fmt.allocPrint(allocator, "[{s}]", .{host});
                return allocator.dupe(u8, host);
            }

            if (needs_brackets) return std.fmt.allocPrint(allocator, "[{s}]:{s}", .{ host, req.url.port });
            return std.fmt.allocPrint(allocator, "{s}:{s}", .{ host, req.url.port });
        }

        fn validateRequestBodyLimit(self: *Self, req: *const Request) RoundTripper.RoundTripError!void {
            if (req.content_length <= 0) return;

            const content_length: usize = @intCast(req.content_length);
            if (content_length > self.options.max_body_bytes) return error.BodyTooLarge;
        }

        fn validateRequest(self: *Self, req: *const Request) RoundTripper.RoundTripError!void {
            if (!isValidToken(req.effectiveMethod())) return error.InvalidMethod;
            if (req.effectiveHost().len == 0) return error.MissingHost;

            try validateHeaderList(req.header, false);
            try validateHeaderList(req.trailer, true);
            try self.validateRequestFramingHeaders(req);

            if (req.trailer.len != 0 and !req.hasBody()) return error.InvalidTrailer;
        }

        fn validateRequestFramingHeaders(self: *Self, req: *const Request) RoundTripper.RoundTripError!void {
            const body = req.body();
            const send_chunked = body != null and self.shouldSendChunkedRequest(req);
            const expected_content_length: i64 = if (req.content_length > 0) req.content_length else 0;

            var header_content_length: ?i64 = null;
            var saw_transfer_encoding = false;

            for (req.header) |hdr| {
                if (hdr.is(Header.content_length)) {
                    const parsed = std.fmt.parseInt(i64, hdr.value, 10) catch return error.InvalidHeader;
                    if (parsed < 0) return error.InvalidHeader;
                    if (header_content_length) |existing| {
                        if (existing != parsed) return error.InvalidHeader;
                    } else {
                        header_content_length = parsed;
                    }
                } else if (hdr.is(Header.transfer_encoding)) {
                    if (saw_transfer_encoding) return error.InvalidHeader;
                    if (!isSupportedChunkedTransferEncoding(hdr.value)) return error.InvalidHeader;
                    saw_transfer_encoding = true;
                }
            }

            if (saw_transfer_encoding) {
                if (!send_chunked) return error.InvalidHeader;
                if (header_content_length != null) return error.InvalidHeader;
            }

            if (header_content_length) |parsed| {
                if (send_chunked) return error.InvalidHeader;
                if (parsed != expected_content_length) return error.InvalidHeader;
            }
        }

        fn readResponse(self: *Self, conn: *?Conn, req: *const Request) RoundTripper.RoundTripError!Response {
            var request_body_state: ?*RequestBodyState = null;
            var lease = ConnLease{
                .conn = conn.*,
            };
            const resp = self.readResponseWithWriter(&lease, req, &request_body_state) catch |err| {
                conn.* = lease.conn;
                return err;
            };
            conn.* = lease.conn;
            return resp;
        }

        fn readResponseWithWriter(
            self: *Self,
            lease: *ConnLease,
            req: *const Request,
            request_body_state: *?*RequestBodyState,
        ) RoundTripper.RoundTripError!Response {
            const allocator = req.allocator;
            var conn_reader = lease.conn orelse unreachable;
            var read_ctx_active = try self.setConnReadContext(conn_reader, req.context());
            defer self.clearConnReadContext(conn_reader, read_ctx_active);
            var buffered = try BufferedConnReader.initAlloc(&conn_reader, allocator, self.options.max_header_bytes);
            var buffered_transferred = false;
            defer if (!buffered_transferred) buffered.deinit();
            var informational_responses: usize = 0;

            while (true) {
                const head_storage = self.readResponseHead(&buffered, allocator) catch |err| {
                    const fallback: RoundTripper.RoundTripError = switch (err) {
                        error.EndOfStream => if (lease.reused) error.ServerClosedIdle else error.InvalidResponse,
                        error.StreamTooLong, error.BufferTooSmall => error.BufferTooSmall,
                        error.ReadFailed => switch (buffered.err() orelse error.Unexpected) {
                            error.TimedOut => self.contextTimeoutError(req),
                            error.ConnectionReset => error.ConnectionReset,
                            error.ConnectionRefused => error.ConnectionRefused,
                            else => error.Unexpected,
                        },
                        else => error.Unexpected,
                    };
                    return self.preferRequestBodyResult(request_body_state.*, fallback);
                };

                var parsed_state: ResponseState = .{
                    .allocator = allocator,
                    .head_storage = head_storage,
                    .headers = &.{},
                    .body_state = null,
                };
                var parsed_state_transferred = false;
                defer if (!parsed_state_transferred) freeResponseStateParts(&parsed_state);

                const parsed = try self.parseHead(&parsed_state);
                if (parsed.status_code == 100) {
                    if (request_body_state.*) |writer| writer.allowBodySend();
                }
                if (isInformationalResponse(parsed.status_code)) {
                    informational_responses += 1;
                    if (informational_responses > max_informational_responses) return error.InvalidResponse;
                    continue;
                }

                var skipped_waiting_request_body = false;
                if (request_body_state.*) |writer| {
                    if (writer.isWaitingForContinue()) {
                        writer.skipBodySend();
                        skipped_waiting_request_body = true;
                    }
                }

                try self.restoreResponseBodyReadTimeout(conn_reader, req);
                try self.validateResponseBodyLimit(req, parsed);

                var state = try allocator.create(ResponseState);
                state.* = parsed_state;
                parsed_state_transferred = true;
                errdefer {
                    if (state.body_state) |body| {
                        body.deinit();
                        allocator.destroy(body);
                    }
                    if (state.tls_state) |*tls_state| tls_state.deinit(allocator);
                    freeResponseStateParts(state);
                    allocator.destroy(state);
                }
                state.tls_state = try self.captureResponseTlsState(conn_reader, allocator);

                const tail = buffered.ioReader().buffered();
                const body_state = try allocator.create(BodyState);
                body_state.* = .{
                    .allocator = allocator,
                    .conn = conn_reader,
                    .buffered = buffered,
                    .ctx = req.context(),
                    .max_header_bytes = self.options.max_header_bytes,
                    .max_trailer_bytes = self.options.max_header_bytes,
                    .max_body_bytes = self.options.max_body_bytes,
                    .transport = self,
                    .pool_key = lease.pool_key,
                    .pool_generation = lease.pool_generation,
                    .reusable = !skipped_waiting_request_body and lease.reusable and self.responseCanReuseConnection(req, parsed),
                    .read_context_active = read_ctx_active,
                };
                read_ctx_active = false;
                body_state.buffered.rd = &body_state.conn;
                buffered_transferred = true;
                errdefer {
                    body_state.deinit();
                    allocator.destroy(body_state);
                }
                body_state.mode = self.responseBodyMode(req, parsed);
                body_state.request_body_state = request_body_state.*;
                state.body_state = body_state;
                body_state.owns_conn = true;
                lease.conn = null;
                lease.pool_key = &.{};
                request_body_state.* = null;

                const has_body_reader = switch (body_state.mode) {
                    .none => false,
                    .fixed => |remaining| remaining != 0,
                    .eof, .chunked => true,
                };

                if (!has_body_reader and tail.len != 0) {
                    body_state.reusable = false;
                }

                if (!has_body_reader) {
                    if (body_state.request_body_state != null) {
                        body_state.reusable = false;
                        body_state.abortRequestBody();
                        try body_state.finishRequestBody();
                        if (body_state.owns_conn) body_state.conn.close();
                    } else {
                        _ = try body_state.finishAndReturnEof();
                    }
                    body_state.close();
                }

                return .{
                    .deinit_ptr = @ptrCast(state),
                    .deinit_fn = responseStateDeinit,
                    .status = parsed.status,
                    .status_code = parsed.status_code,
                    .proto = parsed.proto,
                    .proto_major = parsed.proto_major,
                    .proto_minor = parsed.proto_minor,
                    .header = parsed.headers,
                    .body_reader = if (has_body_reader) ReadCloser.init(body_state) else null,
                    .content_length = if (parsed.content_length) |n| @intCast(n) else @as(i64, -1),
                    .close = !body_state.reusable,
                    .request = req.*,
                    .tls = if (state.tls_state) |tls_state| .{
                        .version = tls_state.version,
                        .cipher_suite = tls_state.cipher_suite,
                        .peer_certificate_der = if (tls_state.peer_certificate_der.len == 0) null else tls_state.peer_certificate_der,
                    } else null,
                };
            }
        }

        fn readResponseHead(self: *Self, buffered: *BufferedConnReader, allocator: Allocator) RoundTripper.RoundTripError![]u8 {
            var reader = TextprotoReader.fromBuffered(buffered);
            const raw = reader.takeHeaderBlockMax(self.options.max_header_bytes, .{}) catch |err| switch (err) {
                error.InvalidLineEnding => return error.InvalidResponse,
                error.BufferTooSmall => return error.BufferTooSmall,
                else => return err,
            };
            return allocator.dupe(u8, raw) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
            };
        }

        fn parseHead(_: *Self, state: *ResponseState) RoundTripper.RoundTripError!ParsedHead {
            const status_line_end = std.mem.indexOf(u8, state.head_storage, "\r\n") orelse return error.InvalidResponse;
            const status_line = state.head_storage[0..status_line_end];

            const first_space = std.mem.indexOfScalar(u8, status_line, ' ') orelse return error.InvalidResponse;
            const proto = status_line[0..first_space];
            const rest = status_line[first_space + 1 ..];
            const second_space = std.mem.indexOfScalar(u8, rest, ' ') orelse return error.InvalidResponse;
            const code_slice = rest[0..second_space];
            const status_slice = rest;
            const status_code = std.fmt.parseInt(u16, code_slice, 10) catch return error.InvalidResponse;

            var proto_major: u8 = 1;
            var proto_minor: u8 = 1;
            if (std.mem.startsWith(u8, proto, "HTTP/")) {
                const version = proto["HTTP/".len..];
                if (std.mem.indexOfScalar(u8, version, '.')) |dot| {
                    proto_major = std.fmt.parseInt(u8, version[0..dot], 10) catch return error.InvalidResponse;
                    proto_minor = std.fmt.parseInt(u8, version[dot + 1 ..], 10) catch return error.InvalidResponse;
                }
            }

            const header_block = state.head_storage[status_line_end + 2 ..];
            const header_count = countHeaderLines(header_block);
            state.headers = if (header_count == 0) &.{} else try state.allocator.alloc(Header, header_count);

            var parsed = ParsedHead{
                .status = status_slice,
                .status_code = status_code,
                .proto = proto,
                .proto_major = proto_major,
                .proto_minor = proto_minor,
                .headers = state.headers,
            };

            var saw_transfer_encoding = false;
            var line_start: usize = 0;
            var header_index: usize = 0;
            while (line_start < header_block.len) {
                const rel_end = std.mem.indexOf(u8, header_block[line_start..], "\r\n") orelse return error.InvalidResponse;
                if (rel_end == 0) break;

                const line = header_block[line_start .. line_start + rel_end];
                const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidResponse;
                const name = std.mem.trim(u8, line[0..colon], " ");
                const value = std.mem.trim(u8, line[colon + 1 ..], " ");
                parsed.headers[header_index] = .{ .name = name, .value = value };
                header_index += 1;

                if (std.ascii.eqlIgnoreCase(name, Header.content_length)) {
                    const content_length = std.fmt.parseInt(usize, value, 10) catch return error.InvalidResponse;
                    if (parsed.chunked) return error.InvalidResponse;
                    if (parsed.content_length) |existing| {
                        if (existing != content_length) return error.InvalidResponse;
                    } else {
                        parsed.content_length = content_length;
                    }
                } else if (std.ascii.eqlIgnoreCase(name, Header.transfer_encoding)) {
                    if (saw_transfer_encoding or parsed.content_length != null) return error.InvalidResponse;
                    if (!isSupportedChunkedTransferEncoding(value)) return error.InvalidResponse;
                    parsed.chunked = true;
                    saw_transfer_encoding = true;
                } else if (std.ascii.eqlIgnoreCase(name, Header.connection)) {
                    if (containsToken(value, "close")) parsed.close = true;
                    if (containsToken(value, "keep-alive")) parsed.keep_alive = true;
                }

                line_start += rel_end + 2;
            }

            return parsed;
        }

        fn responseBodyMode(_: *Self, req: *const Request, parsed: ParsedHead) BodyState.BodyMode {
            if (responseMustBeBodyless(req, parsed.status_code)) return .none;
            if (parsed.chunked) return .{ .chunked = .{} };
            if (parsed.content_length) |len| return .{ .fixed = len };
            return .eof;
        }

        fn responseStateDeinit(ptr: *anyopaque) void {
            const state: *ResponseState = @ptrCast(@alignCast(ptr));
            if (state.body_state) |body| {
                body.deinit();
                state.allocator.destroy(body);
            }
            if (state.tls_state) |*tls_state| tls_state.deinit(state.allocator);
            if (state.headers.len != 0) state.allocator.free(state.headers);
            state.allocator.free(state.head_storage);
            state.allocator.destroy(state);
        }

        fn freeResponseStateParts(state: *const ResponseState) void {
            if (state.headers.len != 0) state.allocator.free(state.headers);
            if (state.head_storage.len != 0) state.allocator.free(state.head_storage);
        }

        fn captureResponseTlsState(self: *Self, conn: Conn, allocator: Allocator) RoundTripper.RoundTripError!?Tls.Conn.ConnectionState {
            _ = self;
            const tls_conn = conn.as(Tls.Conn) catch |err| return switch (err) {
                error.TypeMismatch => null,
            };
            return tls_conn.connectionState(allocator) catch |err| return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.Unexpected,
            };
        }

        fn validateResponseBodyLimit(self: *Self, req: *const Request, parsed: ParsedHead) RoundTripper.RoundTripError!void {
            if (responseMustBeBodyless(req, parsed.status_code)) return;
            if (parsed.content_length) |content_length| {
                if (content_length > self.options.max_body_bytes) return error.BodyTooLarge;
            }
        }

        fn requestRoute(self: *Self, req: *const Request) RoundTripper.RoundTripError!RouteInfo {
            const target_port = defaultPort(req.url) orelse return error.UnsupportedScheme;
            if (std.mem.eql(u8, req.url.scheme, "https")) {
                if (self.options.https_proxy) |proxy| {
                    if (proxy.url.host.len == 0) return error.InvalidProxy;
                    if (!std.mem.eql(u8, proxy.url.scheme, "http")) return error.UnsupportedProxyScheme;
                    const proxy_port = defaultPort(proxy.url) orelse return error.InvalidProxy;
                    return .{
                        .target_port = target_port,
                        .dial_host = proxy.url.host,
                        .dial_port = proxy_port,
                        .proxy = proxy,
                    };
                }
            }
            return .{
                .target_port = target_port,
                .dial_host = req.url.host,
                .dial_port = target_port,
            };
        }

        fn connectionPoolKeyForRoute(self: *Self, req: *const Request, route: RouteInfo) Allocator.Error![]u8 {
            if (route.proxy) |proxy| {
                const proxy_authority = try authorityValue(self.allocator, proxy.url.host, route.dial_port);
                defer self.allocator.free(proxy_authority);
                const target_authority = try authorityValue(self.allocator, req.url.host, route.target_port);
                defer self.allocator.free(target_authority);
                return std.fmt.allocPrint(self.allocator, "https+connect://{s}->{s}", .{ proxy_authority, target_authority });
            }
            return connectionPoolKey(self.allocator, req.url.scheme, req.url.host, route.target_port);
        }

        fn writeConnectRequest(
            self: *Self,
            buffered: *BufferedConnWriter,
            conn: Conn,
            req: *const Request,
            proxy: ProxyConfig,
            target_port: u16,
        ) RoundTripper.RoundTripError!void {
            try validateHeaderList(proxy.connect_headers, false);

            const allocator = req.allocator;
            const authority = try authorityValue(allocator, req.url.host, target_port);
            defer allocator.free(authority);
            const has_proxy_authorization = requestHasHeader(proxy.connect_headers, Header.proxy_authorization);
            const proxy_authorization = if (has_proxy_authorization)
                null
            else
                try proxyAuthorizationValue(allocator, proxy.url);
            defer if (proxy_authorization) |value| allocator.free(value);

            var writer = TextprotoWriter.fromBuffered(buffered);
            try self.writeTextprotoLine(&writer, buffered, conn, req, &.{ "CONNECT ", authority, " HTTP/1.1" });

            var has_host = false;
            for (proxy.connect_headers) |hdr| {
                if (hdr.is(Header.host)) has_host = true;
                try self.writeTextprotoLine(&writer, buffered, conn, req, &.{ hdr.name, ": ", hdr.value });
            }
            if (proxy_authorization) |value| {
                try self.writeTextprotoLine(&writer, buffered, conn, req, &.{ Header.proxy_authorization, ": ", value });
            }
            if (!has_host) try self.writeTextprotoLine(&writer, buffered, conn, req, &.{ Header.host, ": ", authority });
            try self.writeTextprotoLine(&writer, buffered, conn, req, &.{});
        }

        fn readConnectResponse(self: *Self, conn: Conn, req: *const Request) RoundTripper.RoundTripError!void {
            const allocator = req.allocator;
            var conn_reader = conn;
            const read_ctx_active = try self.setConnReadContext(conn_reader, req.context());
            defer self.clearConnReadContext(conn_reader, read_ctx_active);
            var buffered = try BufferedConnReader.initAlloc(&conn_reader, allocator, self.options.max_header_bytes);
            defer buffered.deinit();
            var informational_responses: usize = 0;

            while (true) {
                const head_storage = self.readResponseHead(&buffered, allocator) catch |err| return switch (err) {
                    error.EndOfStream => error.ProxyConnectFailed,
                    error.StreamTooLong, error.BufferTooSmall => error.BufferTooSmall,
                    error.ReadFailed => switch (buffered.err() orelse error.Unexpected) {
                        error.TimedOut => self.contextTimeoutError(req),
                        error.ConnectionReset => error.ConnectionReset,
                        error.ConnectionRefused => error.ConnectionRefused,
                        else => error.Unexpected,
                    },
                    else => error.Unexpected,
                };

                var parsed_state = ResponseState{
                    .allocator = allocator,
                    .head_storage = head_storage,
                    .headers = &.{},
                    .body_state = null,
                };
                defer freeResponseStateParts(&parsed_state);

                const parsed = try self.parseHead(&parsed_state);
                if (isInformationalResponse(parsed.status_code)) {
                    informational_responses += 1;
                    if (informational_responses > max_informational_responses) return error.InvalidResponse;
                    continue;
                }

                switch (parsed.status_code) {
                    200 => {
                        if (parsed.chunked) return error.InvalidResponse;
                        if (parsed.content_length) |content_length| {
                            if (content_length != 0) return error.InvalidResponse;
                        }
                        if (buffered.ioReader().buffered().len != 0) return error.InvalidResponse;
                        return;
                    },
                    407 => return error.ProxyAuthRequired,
                    else => return error.ProxyConnectFailed,
                }
            }
        }

        fn currentIdleGeneration(self: *Self) usize {
            self.idle_mu.lock();
            defer self.idle_mu.unlock();
            return self.idle_generation;
        }

        fn discardLease(self: *Self, lease: *ConnLease) void {
            if (lease.conn) |owned_conn| {
                self.discardConn(owned_conn, lease.pool_key);
            } else if (lease.pool_key.len != 0) {
                self.allocator.free(lease.pool_key);
            }
            lease.conn = null;
            lease.pool_key = &.{};
        }

        fn discardConn(self: *Self, conn: Conn, pool_key: []u8) void {
            if (pool_key.len != 0 and self.maxConnsPerHost() != null) {
                self.idle_mu.lock();
                self.noteConnClosedLocked(pool_key);
                self.idle_mu.unlock();
            }
            conn.deinit();
            if (pool_key.len != 0) self.allocator.free(pool_key);
        }

        fn takeIdleConn(self: *Self, pool_key: []const u8) ?IdleConnTake {
            self.idle_mu.lock();
            defer self.idle_mu.unlock();

            self.pruneExpiredIdleLocked();
            return self.takeIdleConnLocked(pool_key);
        }

        fn takeIdleConnLocked(self: *Self, pool_key: []const u8) ?IdleConnTake {
            var i = self.idle_conns.items.len;
            while (i > 0) {
                i -= 1;
                if (!std.ascii.eqlIgnoreCase(self.idle_conns.items[i].key, pool_key)) continue;
                const idle = self.idle_conns.orderedRemove(i);
                return .{
                    .key = idle.key,
                    .conn = idle.conn,
                    .generation = self.idle_generation,
                };
            }
            return null;
        }

        fn releaseConn(self: *Self, conn: Conn, pool_key: []u8, pool_generation: usize) void {
            var should_close = false;

            self.idle_mu.lock();
            self.pruneExpiredIdleLocked();

            if (pool_generation != self.idle_generation) {
                should_close = true;
            } else if (self.options.max_idle_conns != 0 and self.idle_conns.items.len >= self.options.max_idle_conns) {
                should_close = true;
            } else if (self.countIdleConnsForKeyLocked(pool_key) >= self.maxIdleConnsPerHost()) {
                should_close = true;
            } else {
                self.idle_conns.append(self.allocator, .{
                    .key = pool_key,
                    .conn = conn,
                    .idle_since_ms = lib.time.milliTimestamp(),
                }) catch {
                    should_close = true;
                };
                if (!should_close) {
                    if (self.findHostStateIndexLocked(pool_key)) |idx| {
                        if (self.host_states.items[idx].waiters != 0) {
                            self.host_states.items[idx].cond.signal();
                        }
                    }
                }
            }

            self.idle_mu.unlock();

            if (should_close) {
                self.discardConn(conn, pool_key);
            }
        }

        fn pruneExpiredIdleLocked(self: *Self) void {
            const timeout_ms = self.options.idle_conn_timeout_ms orelse return;
            const now = lib.time.milliTimestamp();

            var i = self.idle_conns.items.len;
            while (i > 0) {
                i -= 1;
                const idle = self.idle_conns.items[i];
                if (now - idle.idle_since_ms < timeout_ms) continue;
                self.closeIdleConn(self.idle_conns.orderedRemove(i));
            }
        }

        fn closeIdleConn(self: *Self, idle: IdleConn) void {
            self.noteConnClosedLocked(idle.key);
            idle.conn.deinit();
            self.allocator.free(idle.key);
        }

        fn countIdleConnsForKeyLocked(self: *Self, pool_key: []const u8) usize {
            var count: usize = 0;
            for (self.idle_conns.items) |idle| {
                if (std.ascii.eqlIgnoreCase(idle.key, pool_key)) count += 1;
            }
            return count;
        }

        fn maxIdleConnsPerHost(self: *Self) usize {
            if (self.options.max_idle_conns_per_host != 0) return self.options.max_idle_conns_per_host;
            return 2;
        }

        fn maxConnsPerHost(self: *Self) ?usize {
            if (self.options.max_conns_per_host == 0) return null;
            return self.options.max_conns_per_host;
        }

        fn getOrCreateHostStateLocked(self: *Self, pool_key: []const u8) Allocator.Error!*HostState {
            if (self.findHostStateIndexLocked(pool_key)) |idx| {
                return &self.host_states.items[idx];
            }

            try self.host_states.append(self.allocator, .{
                .key = try self.allocator.dupe(u8, pool_key),
            });
            return &self.host_states.items[self.host_states.items.len - 1];
        }

        fn findHostStateIndexLocked(self: *Self, pool_key: []const u8) ?usize {
            for (self.host_states.items, 0..) |state, idx| {
                if (std.ascii.eqlIgnoreCase(state.key, pool_key)) return idx;
            }
            return null;
        }

        fn noteConnClosedLocked(self: *Self, pool_key: []const u8) void {
            if (self.maxConnsPerHost() == null) return;
            const idx = self.findHostStateIndexLocked(pool_key) orelse return;
            var should_cleanup = false;
            {
                const state = &self.host_states.items[idx];
                if (state.live_conns != 0) state.live_conns -= 1;
                if (state.waiters != 0) state.cond.signal();
                should_cleanup = state.live_conns == 0 and state.waiters == 0;
            }
            if (should_cleanup) self.freeHostStateLocked(idx);
        }

        fn freeHostStateLocked(self: *Self, idx: usize) void {
            const state = self.host_states.orderedRemove(idx);
            self.allocator.free(state.key);
        }

        fn waitForConnAvailableLocked(self: *Self, req: *const Request, state: *HostState) RoundTripper.RoundTripError!void {
            const ctx = req.context() orelse {
                state.cond.wait(&self.idle_mu);
                return;
            };

            if (ctx.err()) |err| return err;
            if (ctx.deadline()) |deadline_ns| {
                const remaining_ns = deadline_ns - lib.time.nanoTimestamp();
                if (remaining_ns <= 0) return error.DeadlineExceeded;
                state.cond.timedWait(
                    &self.idle_mu,
                    @intCast(@min(remaining_ns, @as(i128, 25 * lib.time.ns_per_ms))),
                ) catch {};
                if (ctx.err()) |err| return err;
                if (deadline_ns <= lib.time.nanoTimestamp()) return error.DeadlineExceeded;
                return;
            }

            state.cond.timedWait(&self.idle_mu, 25 * lib.time.ns_per_ms) catch {};
            if (ctx.err()) |err| return err;
        }

        fn shouldAttemptConnectionReuse(self: *Self, req: *const Request) bool {
            if (self.options.disable_keep_alives) return false;
            if (req.close) return false;
            if (self.requestWantsClose(req)) return false;
            if (req.proto_major < 1) return false;
            if (req.proto_major == 1 and req.proto_minor == 0) return false;
            return true;
        }

        fn requestWantsClose(_: *Self, req: *const Request) bool {
            if (req.close) return true;
            for (req.header) |hdr| {
                if (hdr.is(Header.connection) and containsToken(hdr.value, "close")) return true;
            }
            return false;
        }

        fn responseCanReuseConnection(self: *Self, req: *const Request, parsed: ParsedHead) bool {
            if (!self.shouldAttemptConnectionReuse(req)) return false;
            if (parsed.close) return false;
            if (parsed.proto_major < 1) return false;
            if (parsed.proto_major == 1 and parsed.proto_minor == 0 and !parsed.keep_alive) return false;
            if (!responseMustBeBodyless(req, parsed.status_code) and !parsed.chunked and parsed.content_length == null) {
                return false;
            }
            return true;
        }

        fn shouldWaitForContinue(self: *Self, req: *const Request) bool {
            if (self.options.expect_continue_timeout_ms == 0) return false;
            if (req.body() == null) return false;
            if (req.proto_major < 1) return false;
            if (req.proto_major == 1 and req.proto_minor == 0) return false;
            return requestHasToken(req.header, Header.expect, "100-continue");
        }

        fn shouldRetryRequest(self: *Self, req: *const Request, reused: bool, err: anyerror) bool {
            _ = self;
            if (!reused) return false;
            if (!requestIsReplayable(req)) return false;
            if (!requestBodyIsReplayable(req)) return false;

            return switch (err) {
                error.BrokenPipe,
                error.ConnectionReset,
                error.ServerClosedIdle,
                => true,
                else => false,
            };
        }

        fn contextTimeoutError(_: *Self, req: *const Request) RoundTripper.RoundTripError {
            if (req.context()) |ctx| {
                if (ctx.err()) |err| return err;
                if (contextDeadlineExceeded(ctx)) return error.DeadlineExceeded;
            }
            return error.TimedOut;
        }

        fn mapReadError(self: *Self, err: anyerror, req: *const Request) RoundTripper.RoundTripError {
            return switch (err) {
                error.TimedOut => self.contextTimeoutError(req),
                error.ConnectionReset => error.ConnectionReset,
                error.ConnectionRefused => error.ConnectionRefused,
                else => error.Unexpected,
            };
        }

        fn mapWriteError(self: *Self, err: anyerror, req: *const Request) RoundTripper.RoundTripError {
            return switch (err) {
                error.BrokenPipe => error.BrokenPipe,
                error.ConnectionRefused => error.ConnectionRefused,
                error.ConnectionReset => error.ConnectionReset,
                error.TimedOut => self.requestWriteTimeoutError(req),
                else => error.Unexpected,
            };
        }

        fn requestWriteTimeoutError(self: *Self, req: *const Request) RoundTripper.RoundTripError {
            _ = self;
            if (req.context()) |ctx| {
                if (ctx.err()) |err| return err;
                if (contextDeadlineExceeded(ctx)) return error.DeadlineExceeded;
            }
            return error.TimedOut;
        }

        fn checkRequestSendContext(self: *Self, req: *const Request) RoundTripper.RoundTripError!void {
            _ = self;
            if (req.context()) |ctx| {
                if (ctx.err()) |err| return err;
                if (contextDeadlineExceeded(ctx)) return error.DeadlineExceeded;
            }
        }

        fn preferRequestBodyResult(
            self: *Self,
            request_body_state: ?*RequestBodyState,
            fallback: RoundTripper.RoundTripError,
        ) RoundTripper.RoundTripError {
            _ = self;
            const writer = request_body_state orelse return fallback;
            writer.requestAbort();
            if (writer.finish()) |request_body_err| {
                switch (request_body_err) {
                    error.Canceled,
                    error.DeadlineExceeded,
                    error.TimedOut,
                    => return request_body_err,
                    else => {},
                }
            }
            if (writer.req.context()) |ctx| {
                if (ctx.err()) |ctx_err| {
                    switch (ctx_err) {
                        error.Canceled,
                        error.DeadlineExceeded,
                        => return ctx_err,
                        else => {},
                    }
                }
                if (contextDeadlineExceeded(ctx)) return error.DeadlineExceeded;
            }
            return fallback;
        }

        fn contextDeadlineExceeded(ctx: Context) bool {
            if (ctx.deadline()) |deadline| {
                return lib.time.nanoTimestamp() + context_timeout_grace_ns >= deadline;
            }
            return false;
        }
    };
}

fn countHeaderLines(block: []const u8) usize {
    var count: usize = 0;
    var start: usize = 0;
    while (start < block.len) {
        const rel_end = std.mem.indexOf(u8, block[start..], "\r\n") orelse break;
        if (rel_end == 0) break;
        count += 1;
        start += rel_end + 2;
    }
    return count;
}

fn isInformationalResponse(status_code: u16) bool {
    return status_code >= 100 and status_code < 200 and status_code != 101;
}

fn containsToken(value: []const u8, token: []const u8) bool {
    var start: usize = 0;
    while (start <= value.len) {
        const comma = std.mem.indexOfScalarPos(u8, value, start, ',') orelse value.len;
        const part = std.mem.trim(u8, value[start..comma], " ");
        if (std.ascii.eqlIgnoreCase(part, token)) return true;
        if (comma == value.len) break;
        start = comma + 1;
    }
    return false;
}

fn isSupportedChunkedTransferEncoding(value: []const u8) bool {
    var start: usize = 0;
    var saw_chunked = false;
    while (start <= value.len) {
        const comma = std.mem.indexOfScalarPos(u8, value, start, ',') orelse value.len;
        const part = std.mem.trim(u8, value[start..comma], " ");
        if (part.len == 0) return false;
        if (!std.ascii.eqlIgnoreCase(part, "chunked")) return false;
        if (saw_chunked) return false;
        saw_chunked = true;
        if (comma == value.len) break;
        start = comma + 1;
    }
    return saw_chunked;
}

fn validateHeaderList(headers: []const Header, is_trailer: bool) anyerror!void {
    for (headers) |hdr| {
        if (!isValidToken(hdr.name)) {
            return if (is_trailer) error.InvalidTrailer else error.InvalidHeader;
        }
        if (!isValidHeaderValue(hdr.value)) {
            return if (is_trailer) error.InvalidTrailer else error.InvalidHeader;
        }
        if (is_trailer and isForbiddenTrailerName(hdr.name)) return error.InvalidTrailer;
    }
}

fn isValidToken(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |c| {
        if (c <= 0x20 or c >= 0x7f) return false;
        switch (c) {
            '(', ')', '<', '>', '@', ',', ';', ':', '\\', '"', '/', '[', ']', '?', '=', '{', '}' => return false,
            else => {},
        }
    }
    return true;
}

fn isValidHeaderValue(value: []const u8) bool {
    for (value) |c| {
        if (c == '\r' or c == '\n') return false;
        if (c < 0x20 and c != '\t') return false;
        if (c == 0x7f) return false;
    }
    return true;
}

fn isForbiddenTrailerName(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, Header.transfer_encoding) or
        std.ascii.eqlIgnoreCase(name, Header.content_length) or
        std.ascii.eqlIgnoreCase(name, Header.trailer);
}

fn requestHasHeader(headers: []const Header, name: []const u8) bool {
    for (headers) |hdr| {
        if (hdr.is(name)) return true;
    }
    return false;
}

fn requestHasToken(headers: []const Header, name: []const u8, token: []const u8) bool {
    for (headers) |hdr| {
        if (hdr.is(name) and containsToken(hdr.value, token)) return true;
    }
    return false;
}

fn requestIsReplayable(req: *const Request) bool {
    if (std.ascii.eqlIgnoreCase(req.effectiveMethod(), "GET")) return true;
    if (std.ascii.eqlIgnoreCase(req.effectiveMethod(), "HEAD")) return true;
    if (std.ascii.eqlIgnoreCase(req.effectiveMethod(), "OPTIONS")) return true;
    if (std.ascii.eqlIgnoreCase(req.effectiveMethod(), "TRACE")) return true;
    if (requestHasHeader(req.header, "Idempotency-Key")) return true;
    if (requestHasHeader(req.header, "X-Idempotency-Key")) return true;
    return false;
}

fn requestBodyIsReplayable(req: *const Request) bool {
    if (req.body() == null) return true;
    return req.get_body != null;
}

fn rewindRequest(req: *const Request) anyerror!Request {
    var rewound = req.*;
    if (req.body() == null) return rewound;

    const get_body = req.get_body orelse return error.CannotReplayRequest;
    rewound.body_reader = try get_body.getBody();
    return rewound;
}

fn minTimeoutMs(a: ?u32, b: ?u32) ?u32 {
    if (a == null) return b;
    if (b == null) return a;
    return @min(a.?, b.?);
}

fn defaultPort(u: url_mod.Url) ?u16 {
    if (u.portAsNumber()) |port| return port;
    if (std.mem.eql(u8, u.scheme, "http")) return 80;
    if (std.mem.eql(u8, u.scheme, "https")) return 443;
    return null;
}

fn authorityValue(allocator: std.mem.Allocator, host: []const u8, port: u16) std.mem.Allocator.Error![]u8 {
    const needs_brackets = std.mem.indexOfScalar(u8, host, ':') != null;
    if (needs_brackets) return std.fmt.allocPrint(allocator, "[{s}]:{d}", .{ host, port });
    return std.fmt.allocPrint(allocator, "{s}:{d}", .{ host, port });
}

fn proxyAuthorizationValue(allocator: std.mem.Allocator, proxy_url: url_mod.Url) anyerror!?[]u8 {
    if (proxy_url.username.len == 0 and proxy_url.password.len == 0) return null;

    const raw_userpass_len = proxy_url.username.len + proxy_url.password.len + 1;
    const max_encoded_len = proxy_authorization_value_limit - "Basic ".len;
    if (std.base64.standard.Encoder.calcSize(raw_userpass_len) > max_encoded_len) return error.InvalidProxy;

    var userpass = try std.ArrayList(u8).initCapacity(allocator, raw_userpass_len);
    defer userpass.deinit(allocator);

    try appendPercentDecoded(&userpass, allocator, proxy_url.username);
    try userpass.append(allocator, ':');
    try appendPercentDecoded(&userpass, allocator, proxy_url.password);

    const encoded_len = std.base64.standard.Encoder.calcSize(userpass.items.len);
    if ("Basic ".len + encoded_len > proxy_authorization_value_limit) return error.InvalidProxy;
    const value = try allocator.alloc(u8, "Basic ".len + encoded_len);
    @memcpy(value[0.."Basic ".len], "Basic ");
    _ = std.base64.standard.Encoder.encode(value["Basic ".len..], userpass.items);
    return value;
}

fn appendPercentDecoded(bytes: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) anyerror!void {
    var i: usize = 0;
    while (i < value.len) {
        if (value[i] != '%') {
            try bytes.append(allocator, value[i]);
            i += 1;
            continue;
        }

        if (i + 2 >= value.len) return error.InvalidProxy;
        const hi = hexNibble(value[i + 1]) orelse return error.InvalidProxy;
        const lo = hexNibble(value[i + 2]) orelse return error.InvalidProxy;
        try bytes.append(allocator, (hi << 4) | lo);
        i += 3;
    }
}

fn hexNibble(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

fn connectionPoolKey(allocator: std.mem.Allocator, scheme: []const u8, host: []const u8, port: u16) std.mem.Allocator.Error![]u8 {
    const authority = try authorityValue(allocator, host, port);
    defer allocator.free(authority);
    return std.fmt.allocPrint(allocator, "{s}://{s}", .{ scheme, authority });
}

fn responseMustBeBodyless(req: *const Request, status_code: u16) bool {
    if (std.ascii.eqlIgnoreCase(req.effectiveMethod(), "HEAD")) return true;
    if (status_code >= 100 and status_code < 200) return true;
    return status_code == 204 or status_code == 304;
}

pub fn TestRunner(comptime lib: type, comptime net: type) @import("testing").TestRunner {
    const testing_api = @import("testing");
    return testing_api.TestRunner.fromFn(lib, 3 * 1024 * 1024, struct {
        fn run(_: *testing_api.T, allocator: lib.mem.Allocator) !void {
            const testing = lib.testing;
            const HttpTransport = Transport(lib, net);
            {
                var transport = try HttpTransport.init(allocator, .{
                    .max_header_bytes = 0,
                });
                defer transport.deinit();

                try testing.expectEqual((HttpTransport.Options{}).max_header_bytes, transport.options.max_header_bytes);
                try testing.expectEqual(@as(usize, 32 * 1024), transport.options.max_header_bytes);
            }

            {
                const MockConn = struct {
                    allocator: lib.mem.Allocator,
                    writes: lib.ArrayList(u8),

                    fn init(backing: lib.mem.Allocator) lib.mem.Allocator.Error!@This() {
                        return .{
                            .allocator = backing,
                            .writes = try lib.ArrayList(u8).initCapacity(backing, 0),
                        };
                    }

                    pub fn read(_: *@This(), _: []u8) Conn.ReadError!usize {
                        return error.EndOfStream;
                    }

                    pub fn write(self: *@This(), buf: []const u8) Conn.WriteError!usize {
                        self.writes.appendSlice(self.allocator, buf) catch return error.Unexpected;
                        return buf.len;
                    }

                    pub fn close(_: *@This()) void {}
                    pub fn deinit(self: *@This()) void {
                        self.writes.deinit(self.allocator);
                    }
                    pub fn setReadTimeout(_: *@This(), _: ?u32) void {}
                    pub fn setWriteTimeout(_: *@This(), _: ?u32) void {}
                };

                const BodySource = struct {
                    payload: []const u8,
                    offset: usize = 0,

                    pub fn read(self: *@This(), buf: []u8) anyerror!usize {
                        const remaining = self.payload[self.offset..];
                        const n = @min(buf.len, remaining.len);
                        @memcpy(buf[0..n], remaining[0..n]);
                        self.offset += n;
                        return n;
                    }

                    pub fn close(_: *@This()) void {}
                };

                var transport = try HttpTransport.init(allocator, .{ .max_body_bytes = 16 });
                defer transport.deinit();

                var mock_conn = try MockConn.init(allocator);
                defer mock_conn.deinit();

                const payload = [_]u8{'x'} ** 32;
                var source = BodySource{ .payload = &payload };
                var req = try Request.init(allocator, "POST", "http://example.com/upload");
                req = req.withBody(ReadCloser.init(&source));
                req.content_length = payload.len;

                try testing.expectError(error.BodyTooLarge, transport.writeRequest(Conn.init(&mock_conn), &req));
                try testing.expectEqual(@as(usize, 0), mock_conn.writes.items.len);
            }

            {
                const MockConn = struct {
                    pub fn read(_: *@This(), _: []u8) Conn.ReadError!usize {
                        return error.EndOfStream;
                    }

                    pub fn write(_: *@This(), _: []const u8) Conn.WriteError!usize {
                        return error.ConnectionRefused;
                    }

                    pub fn close(_: *@This()) void {}
                    pub fn deinit(_: *@This()) void {}
                    pub fn setReadTimeout(_: *@This(), _: ?u32) void {}
                    pub fn setWriteTimeout(_: *@This(), _: ?u32) void {}
                };

                var transport = try HttpTransport.init(allocator, .{});
                defer transport.deinit();

                var req = try Request.init(allocator, "GET", "http://example.com/");
                defer req.deinit();

                var mock_conn = MockConn{};
                try testing.expectError(error.ConnectionRefused, transport.writeRequest(Conn.init(&mock_conn), &req));
            }

            {
                const AllocFn = @typeInfo(@TypeOf(allocator.vtable.alloc)).pointer.child;
                const Alignment = @typeInfo(AllocFn).@"fn".params[2].type.?;

                const FailOnLenAllocator = struct {
                    backing: lib.mem.Allocator,
                    fail_len: usize,
                    failed: bool = false,

                    fn init(backing: lib.mem.Allocator, fail_len: usize) @This() {
                        return .{
                            .backing = backing,
                            .fail_len = fail_len,
                        };
                    }

                    fn wrap(self: *@This()) lib.mem.Allocator {
                        return .{
                            .ptr = self,
                            .vtable = &vtable,
                        };
                    }

                    fn alloc(ptr: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
                        const self: *@This() = @ptrCast(@alignCast(ptr));
                        if (!self.failed and len == self.fail_len) {
                            self.failed = true;
                            return null;
                        }
                        return self.backing.rawAlloc(len, alignment, ret_addr);
                    }

                    fn resize(ptr: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
                        const self: *@This() = @ptrCast(@alignCast(ptr));
                        return self.backing.rawResize(memory, alignment, new_len, ret_addr);
                    }

                    fn remap(ptr: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
                        const self: *@This() = @ptrCast(@alignCast(ptr));
                        return self.backing.rawRemap(memory, alignment, new_len, ret_addr);
                    }

                    fn free(ptr: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
                        const self: *@This() = @ptrCast(@alignCast(ptr));
                        self.backing.rawFree(memory, alignment, ret_addr);
                    }

                    const vtable: lib.mem.Allocator.VTable = .{
                        .alloc = alloc,
                        .resize = resize,
                        .remap = remap,
                        .free = free,
                    };
                };

                const MockConn = struct {
                    response: []const u8,
                    offset: usize = 0,
                    close_count: usize = 0,
                    deinit_count: usize = 0,

                    pub fn read(self: *@This(), buf: []u8) Conn.ReadError!usize {
                        const remaining = self.response[self.offset..];
                        if (remaining.len == 0) return 0;
                        const n = @min(buf.len, remaining.len);
                        @memcpy(buf[0..n], remaining[0..n]);
                        self.offset += n;
                        return n;
                    }

                    pub fn write(_: *@This(), buf: []const u8) Conn.WriteError!usize {
                        return buf.len;
                    }

                    pub fn close(self: *@This()) void {
                        self.close_count += 1;
                    }

                    pub fn deinit(self: *@This()) void {
                        self.deinit_count += 1;
                    }

                    pub fn setReadTimeout(_: *@This(), _: ?u32) void {}
                    pub fn setWriteTimeout(_: *@This(), _: ?u32) void {}
                };

                var transport = try HttpTransport.init(allocator, .{});
                defer transport.deinit();

                const body = "payload-tail!";
                var failing_allocator = FailOnLenAllocator.init(allocator, body.len);
                var req = try Request.init(failing_allocator.wrap(), "GET", "http://example.com/");
                var mock_conn = MockConn{
                    .response = "HTTP/1.1 200 OK\r\n" ++
                        "Content-Length: 13\r\n" ++
                        "\r\n" ++
                        body,
                };
                var conn: ?Conn = Conn.init(&mock_conn);

                var resp = try transport.readResponse(&conn, &req);
                defer resp.deinit();

                try testing.expect(!failing_allocator.failed);
                try testing.expectEqual(@as(usize, 0), mock_conn.close_count);
                try testing.expectEqual(@as(usize, 0), mock_conn.deinit_count);
            }

            {
                const MockConn = struct {
                    response: []const u8,
                    offset: usize = 0,
                    closed: bool = false,
                    deinited: bool = false,

                    pub fn read(self: *@This(), buf: []u8) Conn.ReadError!usize {
                        const remaining = self.response[self.offset..];
                        if (remaining.len == 0) return 0;
                        const n = @min(buf.len, remaining.len);
                        @memcpy(buf[0..n], remaining[0..n]);
                        self.offset += n;
                        return n;
                    }

                    pub fn write(_: *@This(), buf: []const u8) Conn.WriteError!usize {
                        return buf.len;
                    }

                    pub fn close(self: *@This()) void {
                        self.closed = true;
                    }

                    pub fn deinit(self: *@This()) void {
                        self.deinited = true;
                    }

                    pub fn setReadTimeout(_: *@This(), _: ?u32) void {}
                    pub fn setWriteTimeout(_: *@This(), _: ?u32) void {}
                };

                var transport = try HttpTransport.init(allocator, .{});
                defer transport.deinit();

                var req = try Request.init(allocator, "GET", "http://example.com/");
                var mock_conn = MockConn{
                    .response = "HTTP/1.1 100 Continue\r\n\r\n" ++
                        "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok",
                };
                var conn: ?Conn = Conn.init(&mock_conn);

                var resp = try transport.readResponse(&conn, &req);
                defer resp.deinit();

                try testing.expect(conn == null);
                try testing.expectEqual(@as(u16, 200), resp.status_code);
                try testing.expectEqualStrings("200 OK", resp.status);

                const body = resp.body() orelse return error.TestUnexpectedResult;
                var buf: [2]u8 = undefined;
                try testing.expectEqual(@as(usize, 2), try body.read(&buf));
                try testing.expectEqualStrings("ok", &buf);
            }

            {
                const too_many_informational_responses = 9;

                const MockConn = struct {
                    response: []const u8,
                    offset: usize = 0,
                    closed: bool = false,
                    deinited: bool = false,

                    pub fn read(self: *@This(), buf: []u8) Conn.ReadError!usize {
                        const remaining = self.response[self.offset..];
                        if (remaining.len == 0) return 0;
                        const n = @min(buf.len, remaining.len);
                        @memcpy(buf[0..n], remaining[0..n]);
                        self.offset += n;
                        return n;
                    }

                    pub fn write(_: *@This(), buf: []const u8) Conn.WriteError!usize {
                        return buf.len;
                    }

                    pub fn close(self: *@This()) void {
                        self.closed = true;
                    }

                    pub fn deinit(self: *@This()) void {
                        self.deinited = true;
                    }

                    pub fn setReadTimeout(_: *@This(), _: ?u32) void {}
                    pub fn setWriteTimeout(_: *@This(), _: ?u32) void {}
                };

                var transport = try HttpTransport.init(allocator, .{});
                defer transport.deinit();

                var req = try Request.init(allocator, "GET", "http://example.com/");
                defer req.deinit();

                var response = lib.ArrayList(u8){};
                defer response.deinit(allocator);
                for (0..too_many_informational_responses) |_| {
                    try response.appendSlice(allocator, "HTTP/1.1 103 Early Hints\r\n\r\n");
                }
                try response.appendSlice(
                    allocator,
                    "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok",
                );

                var mock_conn = MockConn{ .response = response.items };
                var conn: ?Conn = Conn.init(&mock_conn);

                try testing.expectError(error.InvalidResponse, transport.readResponse(&conn, &req));
                if (conn) |owned_conn| owned_conn.deinit();
            }

            {
                const MockConn = struct {
                    response: []const u8,
                    offset: usize = 0,
                    fail_writes: bool = false,
                    closed: bool = false,
                    deinited: bool = false,

                    pub fn read(self: *@This(), buf: []u8) Conn.ReadError!usize {
                        const remaining = self.response[self.offset..];
                        if (remaining.len == 0) return 0;
                        const n = @min(buf.len, remaining.len);
                        @memcpy(buf[0..n], remaining[0..n]);
                        self.offset += n;
                        return n;
                    }

                    pub fn write(self: *@This(), buf: []const u8) Conn.WriteError!usize {
                        if (self.fail_writes) return error.BrokenPipe;
                        return buf.len;
                    }

                    pub fn close(self: *@This()) void {
                        self.closed = true;
                    }

                    pub fn deinit(self: *@This()) void {
                        self.deinited = true;
                    }

                    pub fn setReadTimeout(_: *@This(), _: ?u32) void {}
                    pub fn setWriteTimeout(_: *@This(), _: ?u32) void {}
                };

                const BodySource = struct {
                    payload: []const u8,
                    sent: bool = false,
                    closed: bool = false,

                    pub fn read(self: *@This(), buf: []u8) anyerror!usize {
                        if (self.sent or self.closed) return 0;
                        self.sent = true;
                        @memcpy(buf[0..self.payload.len], self.payload);
                        return self.payload.len;
                    }

                    pub fn close(self: *@This()) void {
                        self.closed = true;
                    }
                };

                var transport = try HttpTransport.init(allocator, .{});
                defer transport.deinit();

                const payload = "payload";
                var source = BodySource{ .payload = payload };
                var req = try Request.init(allocator, "POST", "http://example.com/upload");
                req = req.withBody(ReadCloser.init(&source));
                req.content_length = payload.len;

                var mock_conn = MockConn{
                    .response = "HTTP/1.1 200 OK\r\n" ++
                        "Content-Length: 2\r\n" ++
                        "Connection: close\r\n" ++
                        "\r\n" ++
                        "ok",
                };
                var conn: ?Conn = Conn.init(&mock_conn);
                var conn_writer = conn.?;
                var write_buf: [16]u8 = undefined;
                var buffered_writer = io.BufferedWriter(Conn).init(&conn_writer, &write_buf);
                try transport.writeRequestHead(&buffered_writer, conn_writer, &req);
                try transport.flushBufferedWriter(&buffered_writer, conn_writer, &req);
                mock_conn.fail_writes = true;

                const writer = try HttpTransport.RequestBodyState.spawn(
                    allocator,
                    &transport,
                    conn_writer,
                    buffered_writer,
                    &req,
                    req.body().?,
                    false,
                    payload.len,
                    false,
                    transport.options.expect_continue_timeout_ms,
                    false,
                );
                var request_body_state: ?*HttpTransport.RequestBodyState = writer;
                var lease: HttpTransport.ConnLease = .{ .conn = conn };

                var resp = try transport.readResponseWithWriter(&lease, &req, &request_body_state);
                conn = lease.conn;
                defer resp.deinit();

                try testing.expect(conn == null);
                try testing.expect(request_body_state == null);

                const body = resp.body() orelse return error.TestUnexpectedResult;
                var ok: [2]u8 = undefined;
                try testing.expectEqual(@as(usize, 2), try body.read(&ok));
                try testing.expectEqualStrings("ok", &ok);

                var eof_buf: [1]u8 = undefined;
                try testing.expectError(error.BrokenPipe, body.read(&eof_buf));
                try testing.expect(source.closed);
            }

            {
                const MockConn = struct {
                    mu: lib.Thread.Mutex = .{},
                    cond: lib.Thread.Condition = .{},
                    write_started: bool = false,
                    allow_write_return: bool = false,
                    write_finished: bool = false,
                    closed: bool = false,
                    close_before_write_finished: bool = false,
                    deinited: bool = false,

                    pub fn read(_: *@This(), _: []u8) Conn.ReadError!usize {
                        return 0;
                    }

                    pub fn write(self: *@This(), buf: []const u8) Conn.WriteError!usize {
                        self.mu.lock();
                        self.write_started = true;
                        self.cond.broadcast();
                        while (!self.allow_write_return) self.cond.wait(&self.mu);
                        self.write_finished = true;
                        self.cond.broadcast();
                        self.mu.unlock();
                        return buf.len;
                    }

                    pub fn close(self: *@This()) void {
                        self.mu.lock();
                        if (!self.write_finished) self.close_before_write_finished = true;
                        self.closed = true;
                        self.cond.broadcast();
                        self.mu.unlock();
                    }

                    pub fn deinit(self: *@This()) void {
                        self.deinited = true;
                    }

                    pub fn setReadTimeout(_: *@This(), _: ?u32) void {}
                    pub fn setWriteTimeout(_: *@This(), _: ?u32) void {}
                };

                const BodySource = struct {
                    mu: lib.Thread.Mutex = .{},
                    cond: lib.Thread.Condition = .{},
                    payload: []const u8,
                    offset: usize = 0,
                    closed: bool = false,

                    pub fn read(self: *@This(), buf: []u8) anyerror!usize {
                        if (self.closed) return 0;
                        const remaining = self.payload[self.offset..];
                        if (remaining.len == 0) return 0;
                        const n = @min(buf.len, remaining.len);
                        @memcpy(buf[0..n], remaining[0..n]);
                        self.offset += n;
                        return n;
                    }

                    pub fn close(self: *@This()) void {
                        self.mu.lock();
                        self.closed = true;
                        self.cond.broadcast();
                        self.mu.unlock();
                    }
                };

                var transport = try HttpTransport.init(allocator, .{});
                defer transport.deinit();

                var source = BodySource{ .payload = "x" };
                var req = try Request.init(allocator, "POST", "http://example.com/upload");
                req = req.withBody(ReadCloser.init(&source));
                req.content_length = 1;

                var mock_conn = MockConn{};
                var conn = Conn.init(&mock_conn);
                var body_buf: [16]u8 = undefined;
                var write_buf: [16]u8 = undefined;
                const buffered = io.BufferedReader(Conn).init(&conn, &body_buf);
                const buffered_writer = io.BufferedWriter(Conn).init(&conn, &write_buf);
                const writer = try HttpTransport.RequestBodyState.spawn(
                    allocator,
                    &transport,
                    conn,
                    buffered_writer,
                    &req,
                    req.body().?,
                    false,
                    1,
                    false,
                    transport.options.expect_continue_timeout_ms,
                    false,
                );

                mock_conn.mu.lock();
                while (!mock_conn.write_started) mock_conn.cond.wait(&mock_conn.mu);
                mock_conn.mu.unlock();

                var body_state: HttpTransport.BodyState = .{
                    .allocator = allocator,
                    .conn = conn,
                    .buffered = buffered,
                    .ctx = null,
                    .max_body_bytes = transport.options.max_body_bytes,
                    .owns_conn = true,
                    .request_body_state = writer,
                    .transport = &transport,
                };

                const Closer = struct {
                    fn run(state: *HttpTransport.BodyState) void {
                        state.close();
                    }
                };

                var closer_thread = try lib.Thread.spawn(.{}, Closer.run, .{&body_state});
                source.mu.lock();
                while (!source.closed) source.cond.wait(&source.mu);
                source.mu.unlock();

                mock_conn.mu.lock();
                while (!mock_conn.closed) mock_conn.cond.wait(&mock_conn.mu);
                try testing.expect(mock_conn.closed);
                try testing.expect(mock_conn.close_before_write_finished);
                mock_conn.allow_write_return = true;
                mock_conn.cond.broadcast();
                while (!mock_conn.write_finished) mock_conn.cond.wait(&mock_conn.mu);
                mock_conn.mu.unlock();

                closer_thread.join();
                body_state.deinit();

                try testing.expect(source.closed);
                try testing.expect(mock_conn.closed);
                try testing.expect(mock_conn.deinited);
                try testing.expect(mock_conn.close_before_write_finished);
            }

            {
                var transport = try HttpTransport.init(allocator, .{});
                defer transport.deinit();

                const headers = [_]Header{
                    .{ .name = "Bad Header", .value = "x" },
                };

                var req = try Request.init(allocator, "GET", "http://example.com/");
                req.header = &headers;

                try testing.expectError(error.InvalidHeader, transport.roundTrip(&req));
            }

            {
                var transport = try HttpTransport.init(allocator, .{});
                defer transport.deinit();

                const trailers = [_]Header{
                    Header.init(Header.content_length, "1"),
                };

                const BodySource = struct {
                    pub fn read(_: *@This(), _: []u8) anyerror!usize {
                        return 0;
                    }

                    pub fn close(_: *@This()) void {}
                };

                var source = BodySource{};
                var req = try Request.init(allocator, "POST", "http://example.com/upload");
                req = req.withBody(ReadCloser.init(&source)).withTrailers(&trailers);

                try testing.expectError(error.InvalidTrailer, transport.roundTrip(&req));
            }

            {
                const BodySource = struct {
                    pub fn read(_: *@This(), _: []u8) anyerror!usize {
                        return 0;
                    }

                    pub fn close(_: *@This()) void {}
                };

                var transport = try HttpTransport.init(allocator, .{});
                defer transport.deinit();

                const headers = [_]Header{
                    Header.init(Header.transfer_encoding, "chunked"),
                };

                var source = BodySource{};
                var req = try Request.init(allocator, "POST", "http://example.com/upload");
                req = req.withBody(ReadCloser.init(&source));
                req.content_length = 1;
                req.header = &headers;

                try testing.expectError(error.InvalidHeader, transport.roundTrip(&req));
            }

            {
                const BodySource = struct {
                    pub fn read(_: *@This(), _: []u8) anyerror!usize {
                        return 0;
                    }

                    pub fn close(_: *@This()) void {}
                };

                var transport = try HttpTransport.init(allocator, .{});
                defer transport.deinit();

                const headers = [_]Header{
                    Header.init(Header.content_length, "1"),
                };

                var source = BodySource{};
                var req = try Request.init(allocator, "POST", "http://example.com/upload");
                req = req.withBody(ReadCloser.init(&source));
                req.header = &headers;

                try testing.expectError(error.InvalidHeader, transport.roundTrip(&req));
            }

            {
                const OwnedBody = struct {
                    alloc: lib.mem.Allocator,
                    payload: []const u8,
                    offset: usize = 0,

                    pub fn read(self: *@This(), buf: []u8) anyerror!usize {
                        const remaining = self.payload[self.offset..];
                        if (remaining.len == 0) return 0;
                        const n = @min(buf.len, remaining.len);
                        @memcpy(buf[0..n], remaining[0..n]);
                        self.offset += n;
                        return n;
                    }

                    pub fn close(self: *@This()) void {
                        self.alloc.destroy(self);
                    }
                };

                const Factory = struct {
                    alloc: lib.mem.Allocator,
                    payload: []const u8,
                    calls: usize = 0,

                    pub fn getBody(self: *@This()) anyerror!ReadCloser {
                        self.calls += 1;
                        const body = try self.alloc.create(OwnedBody);
                        body.* = .{ .alloc = self.alloc, .payload = self.payload };
                        return ReadCloser.init(body);
                    }
                };

                var factory = Factory{ .alloc = allocator, .payload = "retry me" };
                const initial_body = try allocator.create(OwnedBody);
                initial_body.* = .{ .alloc = allocator, .payload = "retry me" };

                var req = try Request.init(allocator, "POST", "http://example.com/retry");
                req = req.withBody(ReadCloser.init(initial_body));
                req = req.withGetBody(Request.GetBody.init(&factory));
                req.content_length = "retry me".len;

                var rewound = try rewindRequest(&req);
                defer rewound.body().?.close();
                defer req.body().?.close();

                try testing.expectEqual(@as(usize, 1), factory.calls);

                var reader = rewound.body().?;
                var buf: [16]u8 = undefined;
                const n = try reader.read(&buf);
                try testing.expectEqualStrings("retry me", buf[0..n]);
            }

            {
                const OwnedBody = struct {
                    alloc: lib.mem.Allocator,
                    payload: []const u8,
                    offset: usize = 0,

                    pub fn read(self: *@This(), buf: []u8) anyerror!usize {
                        const remaining = self.payload[self.offset..];
                        if (remaining.len == 0) return 0;
                        const n = @min(buf.len, remaining.len);
                        @memcpy(buf[0..n], remaining[0..n]);
                        self.offset += n;
                        return n;
                    }

                    pub fn close(self: *@This()) void {
                        self.alloc.destroy(self);
                    }
                };

                const Factory = struct {
                    alloc: lib.mem.Allocator,
                    payload: []const u8,

                    pub fn getBody(self: *@This()) anyerror!ReadCloser {
                        const body = try self.alloc.create(OwnedBody);
                        body.* = .{ .alloc = self.alloc, .payload = self.payload };
                        return ReadCloser.init(body);
                    }
                };

                var transport = try HttpTransport.init(allocator, .{});
                defer transport.deinit();

                var get_req = try Request.init(allocator, "GET", "http://example.com/");
                try testing.expect(transport.shouldRetryRequest(&get_req, true, error.ServerClosedIdle));
                try testing.expect(!transport.shouldRetryRequest(&get_req, false, error.ServerClosedIdle));

                const post_body = try allocator.create(OwnedBody);
                post_body.* = .{ .alloc = allocator, .payload = "x" };
                var post_req = try Request.init(allocator, "POST", "http://example.com/");
                post_req = post_req.withBody(ReadCloser.init(post_body));
                post_req.content_length = 1;
                defer post_req.body().?.close();
                try testing.expect(!transport.shouldRetryRequest(&post_req, true, error.ServerClosedIdle));

                var factory = Factory{ .alloc = allocator, .payload = "x" };
                const headers = [_]Header{
                    Header.init("Idempotency-Key", "abc"),
                };
                const replay_body = try allocator.create(OwnedBody);
                replay_body.* = .{ .alloc = allocator, .payload = "x" };
                var replay_req = try Request.init(allocator, "POST", "http://example.com/");
                replay_req = replay_req.withBody(ReadCloser.init(replay_body));
                replay_req = replay_req.withGetBody(Request.GetBody.init(&factory));
                replay_req.header = &headers;
                replay_req.content_length = 1;
                defer replay_req.body().?.close();
                try testing.expect(transport.shouldRetryRequest(&replay_req, true, error.ServerClosedIdle));
            }

            {
                const MockConn = struct {
                    allocator: lib.mem.Allocator,
                    writes: lib.ArrayList(u8),

                    fn init(backing: lib.mem.Allocator) lib.mem.Allocator.Error!@This() {
                        return .{
                            .allocator = backing,
                            .writes = try lib.ArrayList(u8).initCapacity(backing, 0),
                        };
                    }

                    pub fn read(_: *@This(), _: []u8) Conn.ReadError!usize {
                        return error.EndOfStream;
                    }

                    pub fn write(self: *@This(), buf: []const u8) Conn.WriteError!usize {
                        self.writes.appendSlice(self.allocator, buf) catch return error.Unexpected;
                        return buf.len;
                    }

                    pub fn close(_: *@This()) void {}
                    pub fn deinit(self: *@This()) void {
                        self.writes.deinit(self.allocator);
                    }
                    pub fn setReadTimeout(_: *@This(), _: ?u32) void {}
                    pub fn setWriteTimeout(_: *@This(), _: ?u32) void {}
                };

                const BodySource = struct {
                    payload: []const u8,
                    offset: usize = 0,

                    pub fn read(self: *@This(), buf: []u8) anyerror!usize {
                        const remaining = self.payload[self.offset..];
                        if (remaining.len == 0) return 0;
                        const n = @min(buf.len, remaining.len);
                        @memcpy(buf[0..n], remaining[0..n]);
                        self.offset += n;
                        return n;
                    }

                    pub fn close(_: *@This()) void {}
                };

                var transport = try HttpTransport.init(allocator, .{});
                defer transport.deinit();
                var mock_conn = try MockConn.init(allocator);
                defer mock_conn.deinit();

                var source = BodySource{ .payload = "hello" };
                var req = try Request.init(allocator, "POST", "http://example.com/continue");
                req = req.withBody(ReadCloser.init(&source));
                req.content_length = 5;
                var conn = Conn.init(&mock_conn);
                var write_buf: [16]u8 = undefined;
                const buffered_writer = io.BufferedWriter(Conn).init(&conn, &write_buf);

                const writer = try HttpTransport.RequestBodyState.spawn(
                    allocator,
                    &transport,
                    conn,
                    buffered_writer,
                    &req,
                    req.body().?,
                    false,
                    5,
                    true,
                    1000,
                    false,
                );
                defer writer.destroy();

                lib.Thread.sleep(10 * lib.time.ns_per_ms);
                try testing.expectEqual(@as(usize, 0), mock_conn.writes.items.len);

                writer.allowBodySend();
                try testing.expect(writer.finish() == null);
                try testing.expectEqualStrings("hello", mock_conn.writes.items);
            }

            {
                const MockConn = struct {
                    allocator: lib.mem.Allocator,
                    writes: lib.ArrayList(u8),

                    fn init(backing: lib.mem.Allocator) lib.mem.Allocator.Error!@This() {
                        return .{
                            .allocator = backing,
                            .writes = try lib.ArrayList(u8).initCapacity(backing, 0),
                        };
                    }

                    pub fn read(_: *@This(), _: []u8) Conn.ReadError!usize {
                        return error.EndOfStream;
                    }

                    pub fn write(self: *@This(), buf: []const u8) Conn.WriteError!usize {
                        self.writes.appendSlice(self.allocator, buf) catch return error.Unexpected;
                        return buf.len;
                    }

                    pub fn close(_: *@This()) void {}
                    pub fn deinit(self: *@This()) void {
                        self.writes.deinit(self.allocator);
                    }
                    pub fn setReadTimeout(_: *@This(), _: ?u32) void {}
                    pub fn setWriteTimeout(_: *@This(), _: ?u32) void {}
                };

                const BodySource = struct {
                    payload: []const u8,
                    offset: usize = 0,

                    pub fn read(self: *@This(), buf: []u8) anyerror!usize {
                        const remaining = self.payload[self.offset..];
                        if (remaining.len == 0) return 0;
                        const n = @min(buf.len, remaining.len);
                        @memcpy(buf[0..n], remaining[0..n]);
                        self.offset += n;
                        return n;
                    }

                    pub fn close(_: *@This()) void {}
                };

                var transport = try HttpTransport.init(allocator, .{});
                defer transport.deinit();
                var mock_conn = try MockConn.init(allocator);
                defer mock_conn.deinit();

                var source = BodySource{ .payload = "later" };
                var req = try Request.init(allocator, "POST", "http://example.com/continue-timeout");
                req = req.withBody(ReadCloser.init(&source));
                req.content_length = 5;
                var conn = Conn.init(&mock_conn);
                var write_buf: [16]u8 = undefined;
                const buffered_writer = io.BufferedWriter(Conn).init(&conn, &write_buf);

                const writer = try HttpTransport.RequestBodyState.spawn(
                    allocator,
                    &transport,
                    conn,
                    buffered_writer,
                    &req,
                    req.body().?,
                    false,
                    5,
                    true,
                    10,
                    false,
                );
                defer writer.destroy();

                try testing.expect(writer.finish() == null);
                try testing.expectEqualStrings("later", mock_conn.writes.items);
            }

            {
                const MockConn = struct {
                    response: []const u8,
                    offset: usize = 0,

                    pub fn read(self: *@This(), buf: []u8) Conn.ReadError!usize {
                        const remaining = self.response[self.offset..];
                        if (remaining.len == 0) return 0;
                        const n = @min(buf.len, remaining.len);
                        @memcpy(buf[0..n], remaining[0..n]);
                        self.offset += n;
                        return n;
                    }

                    pub fn write(_: *@This(), buf: []const u8) Conn.WriteError!usize {
                        return buf.len;
                    }

                    pub fn close(_: *@This()) void {}
                    pub fn deinit(_: *@This()) void {}
                    pub fn setReadTimeout(_: *@This(), _: ?u32) void {}
                    pub fn setWriteTimeout(_: *@This(), _: ?u32) void {}
                };

                var transport = try HttpTransport.init(allocator, .{});
                defer transport.deinit();

                var req = try Request.init(allocator, "GET", "http://example.com/");
                var mock_conn = MockConn{
                    .response = "HTTP/1.1 200 OK\r\n" ++
                        "Content-Length: 1\r\n" ++
                        "Content-Length: 2\r\n" ++
                        "Connection: close\r\n\r\nx",
                };
                var conn: ?Conn = Conn.init(&mock_conn);

                try testing.expectError(error.InvalidResponse, transport.readResponse(&conn, &req));
                if (conn) |owned_conn| owned_conn.deinit();
            }

            {
                const MockConn = struct {
                    response: []const u8,
                    offset: usize = 0,

                    pub fn read(self: *@This(), buf: []u8) Conn.ReadError!usize {
                        const remaining = self.response[self.offset..];
                        if (remaining.len == 0) return 0;
                        const n = @min(buf.len, remaining.len);
                        @memcpy(buf[0..n], remaining[0..n]);
                        self.offset += n;
                        return n;
                    }

                    pub fn write(_: *@This(), buf: []const u8) Conn.WriteError!usize {
                        return buf.len;
                    }

                    pub fn close(_: *@This()) void {}
                    pub fn deinit(_: *@This()) void {}
                    pub fn setReadTimeout(_: *@This(), _: ?u32) void {}
                    pub fn setWriteTimeout(_: *@This(), _: ?u32) void {}
                };

                var transport = try HttpTransport.init(allocator, .{});
                defer transport.deinit();

                var req = try Request.init(allocator, "GET", "http://example.com/");
                var mock_conn = MockConn{
                    .response = "HTTP/1.1 200 OK\r\n" ++
                        "Content-Length: 1\r\n" ++
                        "Transfer-Encoding: chunked\r\n" ++
                        "Connection: close\r\n\r\n" ++
                        "1\r\na\r\n0\r\n\r\n",
                };
                var conn: ?Conn = Conn.init(&mock_conn);

                try testing.expectError(error.InvalidResponse, transport.readResponse(&conn, &req));
                if (conn) |owned_conn| owned_conn.deinit();
            }

            {
                const MockConn = struct {
                    response: []const u8,
                    offset: usize = 0,

                    pub fn read(self: *@This(), buf: []u8) Conn.ReadError!usize {
                        const remaining = self.response[self.offset..];
                        if (remaining.len == 0) return 0;
                        const n = @min(buf.len, remaining.len);
                        @memcpy(buf[0..n], remaining[0..n]);
                        self.offset += n;
                        return n;
                    }

                    pub fn write(_: *@This(), buf: []const u8) Conn.WriteError!usize {
                        return buf.len;
                    }

                    pub fn close(_: *@This()) void {}
                    pub fn deinit(_: *@This()) void {}
                    pub fn setReadTimeout(_: *@This(), _: ?u32) void {}
                    pub fn setWriteTimeout(_: *@This(), _: ?u32) void {}
                };

                var transport = try HttpTransport.init(allocator, .{ .max_header_bytes = 80 });
                defer transport.deinit();

                const trailer_fill = [_]u8{'a'} ** 96;
                const response = try lib.fmt.allocPrint(
                    allocator,
                    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n1\r\na\r\nX-Long: {s}\r\n\r\n",
                    .{&trailer_fill},
                );
                defer allocator.free(response);

                var req = try Request.init(allocator, "GET", "http://example.com/");
                var mock_conn = MockConn{ .response = response };
                var conn: ?Conn = Conn.init(&mock_conn);

                var resp = try transport.readResponse(&conn, &req);
                defer resp.deinit();

                const body = resp.body() orelse return error.TestUnexpectedResult;
                var first: [1]u8 = undefined;
                try testing.expectEqual(@as(usize, 1), try body.read(&first));
                try testing.expectEqualStrings("a", &first);

                var eof_buf: [1]u8 = undefined;
                try testing.expectError(error.InvalidResponse, body.read(&eof_buf));
            }

            {
                const MockConn = struct {
                    response: []const u8,
                    offset: usize = 0,

                    pub fn read(self: *@This(), buf: []u8) Conn.ReadError!usize {
                        const remaining = self.response[self.offset..];
                        if (remaining.len == 0) return 0;
                        const n = @min(buf.len, remaining.len);
                        @memcpy(buf[0..n], remaining[0..n]);
                        self.offset += n;
                        return n;
                    }

                    pub fn write(_: *@This(), buf: []const u8) Conn.WriteError!usize {
                        return buf.len;
                    }

                    pub fn close(_: *@This()) void {}
                    pub fn deinit(_: *@This()) void {}
                    pub fn setReadTimeout(_: *@This(), _: ?u32) void {}
                    pub fn setWriteTimeout(_: *@This(), _: ?u32) void {}
                };

                var transport = try HttpTransport.init(allocator, .{ .max_header_bytes = 80 });
                defer transport.deinit();

                const trailer_fill = [_]u8{'b'} ** 70;
                const response = try lib.fmt.allocPrint(
                    allocator,
                    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n1\r\na\r\n0\r\nX-Test: {s}\r\n\r\n",
                    .{&trailer_fill},
                );
                defer allocator.free(response);

                var req = try Request.init(allocator, "GET", "http://example.com/");
                var mock_conn = MockConn{ .response = response };
                var conn: ?Conn = Conn.init(&mock_conn);

                var resp = try transport.readResponse(&conn, &req);
                defer resp.deinit();

                const body = resp.body() orelse return error.TestUnexpectedResult;
                var buf: [1]u8 = undefined;
                try testing.expectEqual(@as(usize, 1), try body.read(&buf));
                try testing.expectEqualStrings("a", &buf);

                try testing.expectEqual(@as(usize, 0), try body.read(&buf));
            }

            {
                const MockConn = struct {
                    response: []const u8,
                    offset: usize = 0,

                    pub fn read(self: *@This(), buf: []u8) Conn.ReadError!usize {
                        const remaining = self.response[self.offset..];
                        if (remaining.len == 0) return 0;
                        const n = @min(buf.len, remaining.len);
                        @memcpy(buf[0..n], remaining[0..n]);
                        self.offset += n;
                        return n;
                    }

                    pub fn write(_: *@This(), buf: []const u8) Conn.WriteError!usize {
                        return buf.len;
                    }

                    pub fn close(_: *@This()) void {}
                    pub fn deinit(_: *@This()) void {}
                    pub fn setReadTimeout(_: *@This(), _: ?u32) void {}
                    pub fn setWriteTimeout(_: *@This(), _: ?u32) void {}
                };

                var transport = try HttpTransport.init(allocator, .{ .max_header_bytes = 512 });
                defer transport.deinit();

                const extension = [_]u8{'x'} ** 180;
                const response = try lib.fmt.allocPrint(
                    allocator,
                    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n1;{s}\r\na\r\n0\r\n\r\n",
                    .{&extension},
                );
                defer allocator.free(response);

                var req = try Request.init(allocator, "GET", "http://example.com/");
                var mock_conn = MockConn{ .response = response };
                var conn: ?Conn = Conn.init(&mock_conn);

                var resp = try transport.readResponse(&conn, &req);
                defer resp.deinit();

                const body = resp.body() orelse return error.TestUnexpectedResult;
                var buf: [1]u8 = undefined;
                try testing.expectEqual(@as(usize, 1), try body.read(&buf));
                try testing.expectEqualStrings("a", &buf);
                try testing.expectEqual(@as(usize, 0), try body.read(&buf));
            }

            {
                const MockConn = struct {
                    response: []const u8,
                    offset: usize = 0,

                    pub fn read(self: *@This(), buf: []u8) Conn.ReadError!usize {
                        const remaining = self.response[self.offset..];
                        if (remaining.len == 0) return 0;
                        const n = @min(buf.len, remaining.len);
                        @memcpy(buf[0..n], remaining[0..n]);
                        self.offset += n;
                        return n;
                    }

                    pub fn write(_: *@This(), buf: []const u8) Conn.WriteError!usize {
                        return buf.len;
                    }

                    pub fn close(_: *@This()) void {}
                    pub fn deinit(_: *@This()) void {}
                    pub fn setReadTimeout(_: *@This(), _: ?u32) void {}
                    pub fn setWriteTimeout(_: *@This(), _: ?u32) void {}
                };

                var transport = try HttpTransport.init(allocator, .{ .max_header_bytes = 1024 });
                defer transport.deinit();

                const trailer_fill = [_]u8{'t'} ** 700;
                const response = try lib.fmt.allocPrint(
                    allocator,
                    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n1\r\na\r\n0\r\nX-Large: {s}\r\n\r\n",
                    .{&trailer_fill},
                );
                defer allocator.free(response);

                var req = try Request.init(allocator, "GET", "http://example.com/");
                var mock_conn = MockConn{ .response = response };
                var conn: ?Conn = Conn.init(&mock_conn);

                var resp = try transport.readResponse(&conn, &req);
                defer resp.deinit();

                const body = resp.body() orelse return error.TestUnexpectedResult;
                var buf: [1]u8 = undefined;
                try testing.expectEqual(@as(usize, 1), try body.read(&buf));
                try testing.expectEqualStrings("a", &buf);
                try testing.expectEqual(@as(usize, 0), try body.read(&buf));
            }
        }
    }.run);
}
