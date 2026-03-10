const std = @import("std");
const ws = @import("ws.zig");
const outbox_mod = @import("outbox.zig");
const DevRouter = outbox_mod.DevRouter;

const max_handlers = 16;

pub const Handler = struct {
    dev: []const u8,
    ctx: *anyopaque,
    onEvent: *const fn (ctx: *anyopaque, json: std.json.ObjectMap) void,
};

pub const EmitFn = *const fn (*RemoteHal, []const u8) void;

pub const RemoteHal = struct {
    emit_fn: EmitFn,
    running: *std.atomic.Value(bool),
    handlers: [max_handlers]?Handler = .{null} ** max_handlers,
    handler_count: usize = 0,
    write_mutex: std.Thread.Mutex = .{},
    stream: ?std.net.Stream = null,
    router: ?*DevRouter = null,

    pub fn initWs(stream: std.net.Stream, running: *std.atomic.Value(bool)) RemoteHal {
        return .{ .emit_fn = &emitWs, .running = running, .stream = stream };
    }

    pub fn initTest(running: *std.atomic.Value(bool), router: *DevRouter) RemoteHal {
        return .{ .emit_fn = &emitTest, .running = running, .router = router };
    }

    pub fn register(self: *RemoteHal, dev: []const u8, ctx: *anyopaque, cb: *const fn (*anyopaque, std.json.ObjectMap) void) void {
        if (self.handler_count >= max_handlers) return;
        self.handlers[self.handler_count] = .{ .dev = dev, .ctx = ctx, .onEvent = cb };
        self.handler_count += 1;
    }

    pub fn emit(self: *RemoteHal, payload: []const u8) void {
        self.emit_fn(self, payload);
    }

    pub fn startReader(self: *RemoteHal) !std.Thread {
        return std.Thread.spawn(.{}, readerLoop, .{self});
    }

    pub fn dispatchRaw(self: *RemoteHal, json: []const u8) void {
        const parsed = std.json.parseFromSlice(
            std.json.Value,
            std.heap.page_allocator,
            json,
            .{},
        ) catch return;
        defer parsed.deinit();

        const obj = switch (parsed.value) {
            .object => |o| o,
            else => return,
        };

        self.dispatchObj(obj);
    }

    fn emitWs(self: *RemoteHal, payload: []const u8) void {
        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        if (self.stream) |s| ws.sendText(s, payload) catch {};
    }

    fn emitTest(self: *RemoteHal, payload: []const u8) void {
        if (self.router) |r| r.route(payload);
    }

    fn readerLoop(self: *RemoteHal) void {
        const stream = self.stream orelse return;
        var frame_buf: [4096]u8 = undefined;
        while (self.running.load(.acquire)) {
            const frame = ws.readFrame(stream, &frame_buf) catch break;

            switch (frame.opcode) {
                0x8 => {
                    self.write_mutex.lock();
                    defer self.write_mutex.unlock();
                    ws.sendClose(stream);
                    break;
                },
                0x1 => self.dispatchPayload(frame.payload),
                else => {},
            }
        }
        self.running.store(false, .release);
    }

    fn dispatchPayload(self: *RemoteHal, payload: []u8) void {
        const parsed = std.json.parseFromSlice(
            std.json.Value,
            std.heap.page_allocator,
            payload,
            .{},
        ) catch return;
        defer parsed.deinit();

        const obj = switch (parsed.value) {
            .object => |o| o,
            else => return,
        };

        self.dispatchObj(obj);
    }

    fn dispatchObj(self: *RemoteHal, obj: std.json.ObjectMap) void {
        const dev = switch (obj.get("dev") orelse return) {
            .string => |s| s,
            else => return,
        };

        for (self.handlers[0..self.handler_count]) |maybe_h| {
            const h = maybe_h orelse continue;
            if (std.mem.eql(u8, h.dev, dev)) {
                h.onEvent(h.ctx, obj);
            }
        }
    }
};
