//! ServerMux — topic-based request router layered on xfer read transport.

const att = @import("../att.zig");
const Chunk = @import("Chunk.zig");

pub fn ServerMux(comptime lib: type, comptime ServerType: type) type {
    return struct {
        const Self = @This();

        pub const Topic = Chunk.Topic;
        pub const RequestId = Chunk.RequestId;
        pub const Request = struct {
            conn_handle: u16,
            service_uuid: u16,
            char_uuid: u16,
            topic: Topic,
            request_id: ?RequestId = null,
            // Raw read-start metadata bytes after the magic prefix.
            data: []const u8 = &.{},
        };
        pub const HandlerFn = *const fn (?*anyopaque, *const Request, *ServerType.ReadXResponseWriter) void;

        const Route = struct {
            handler: HandlerFn,
            ctx: ?*anyopaque,
        };

        allocator: lib.mem.Allocator,
        routes: lib.AutoHashMapUnmanaged(Topic, Route) = .{},

        pub fn init(allocator: lib.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            self.routes.deinit(self.allocator);
            self.* = undefined;
        }

        pub fn handle(self: *Self, topic: Topic, handler: HandlerFn, ctx: ?*anyopaque) !void {
            if (self.routes.contains(topic)) return error.DuplicateTopic;
            try self.routes.put(self.allocator, topic, .{
                .handler = handler,
                .ctx = ctx,
            });
        }

        pub fn xHandler(self: *Self) ServerType.XHandler {
            _ = self;
            return .{ .read = onRead };
        }

        fn onRead(ctx: ?*anyopaque, req: *const ServerType.ReadXRequest, rw: *ServerType.ReadXResponseWriter) void {
            const raw = ctx orelse {
                rw.err(@intFromEnum(att.ErrorCode.request_not_supported));
                return;
            };
            const self: *Self = @ptrCast(@alignCast(raw));
            const meta = Chunk.decodeReadStartMetadata(req.data) catch {
                rw.err(@intFromEnum(att.ErrorCode.request_not_supported));
                return;
            };

            const route = self.routes.get(meta.topic) orelse {
                rw.err(@intFromEnum(att.ErrorCode.request_not_supported));
                return;
            };

            const mux_req: Request = .{
                .conn_handle = req.conn_handle,
                .service_uuid = req.service_uuid,
                .char_uuid = req.char_uuid,
                .topic = meta.topic,
                .request_id = meta.request_id,
                .data = req.data,
            };
            route.handler(route.ctx, &mux_req, rw);
        }
    };
}

test "bt/unit_tests/host/xfer/ServerMux/handle_rejects_duplicate_topics" {
    const std = @import("std");

    const FakeServer = struct {
        pub const ReadXRequest = struct {
            conn_handle: u16,
            service_uuid: u16,
            char_uuid: u16,
            data: []const u8 = &.{},
        };
        pub const ReadXResponseWriter = struct {
            pub fn write(_: *@This(), _: []const u8) void {}
            pub fn err(_: *@This(), _: u8) void {}
        };
        pub const XHandler = struct {
            read: ?*const fn (?*anyopaque, *const ReadXRequest, *ReadXResponseWriter) void = null,
            write: ?*const fn (?*anyopaque, *const anyopaque) void = null,
        };
    };

    const Mux = ServerMux(std, FakeServer);

    const Handler = struct {
        fn handle(_: ?*anyopaque, _: *const Mux.Request, _: *FakeServer.ReadXResponseWriter) void {}
    };

    var mux = Mux.init(std.testing.allocator);
    defer mux.deinit();

    try mux.handle(1, Handler.handle, null);
    try std.testing.expectError(error.DuplicateTopic, mux.handle(1, Handler.handle, null));
}
