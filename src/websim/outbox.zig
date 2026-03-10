const std = @import("std");

pub const Outbox = struct {
    messages: std.ArrayList([]u8),
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},

    pub fn init(allocator: std.mem.Allocator) Outbox {
        return .{ .messages = .empty, .allocator = allocator };
    }

    pub fn deinit(self: *Outbox) void {
        for (self.messages.items) |msg| self.allocator.free(msg);
        self.messages.deinit(self.allocator);
    }

    pub fn push(self: *Outbox, payload: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const copy = self.allocator.dupe(u8, payload) catch return;
        self.messages.append(self.allocator, copy) catch {
            self.allocator.free(copy);
            return;
        };
        self.cond.signal();
    }

    pub fn pop(self: *Outbox, timeout_ms: u32) ?[]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.messages.items.len > 0) return self.removeFirst();

        self.cond.timedWait(&self.mutex, @as(u64, timeout_ms) * std.time.ns_per_ms) catch {};

        if (self.messages.items.len > 0) return self.removeFirst();
        return null;
    }

    fn removeFirst(self: *Outbox) []u8 {
        return self.messages.orderedRemove(0);
    }
};

const max_dev_outboxes = 16;

pub const DevRouter = struct {
    entries: [max_dev_outboxes]?Entry = .{null} ** max_dev_outboxes,
    count: usize = 0,
    allocator: std.mem.Allocator,
    fallback: Outbox,

    const Entry = struct {
        dev: [64]u8,
        dev_len: usize,
        outbox: *Outbox,

        fn devSlice(self: *const Entry) []const u8 {
            return self.dev[0..self.dev_len];
        }
    };

    pub fn init(allocator: std.mem.Allocator) DevRouter {
        return .{ .allocator = allocator, .fallback = Outbox.init(allocator) };
    }

    pub fn deinit(self: *DevRouter) void {
        for (self.entries[0..self.count]) |maybe_e| {
            if (maybe_e) |e| {
                e.outbox.deinit();
                self.allocator.destroy(e.outbox);
            }
        }
        self.fallback.deinit();
    }

    pub fn track(self: *DevRouter, dev: []const u8) *Outbox {
        for (self.entries[0..self.count]) |*maybe_e| {
            if (maybe_e.*) |*e| {
                if (std.mem.eql(u8, e.devSlice(), dev)) return e.outbox;
            }
        }
        if (self.count >= max_dev_outboxes) return &self.fallback;
        const ob = self.allocator.create(Outbox) catch return &self.fallback;
        ob.* = Outbox.init(self.allocator);
        var entry: Entry = .{ .dev = undefined, .dev_len = dev.len, .outbox = ob };
        @memcpy(entry.dev[0..dev.len], dev);
        self.entries[self.count] = entry;
        self.count += 1;
        return ob;
    }

    pub fn route(self: *DevRouter, payload: []const u8) void {
        var dev_buf: [64]u8 = undefined;
        const dev_len = extractDevInto(payload, &dev_buf);
        if (dev_len > 0) {
            const dev = dev_buf[0..dev_len];
            for (self.entries[0..self.count]) |maybe_e| {
                if (maybe_e) |e| {
                    if (std.mem.eql(u8, e.devSlice(), dev)) {
                        e.outbox.push(payload);
                        return;
                    }
                }
            }
        }
        self.fallback.push(payload);
    }
};

fn extractDevInto(payload: []const u8, buf: []u8) usize {
    const dev_key = "\"dev\":\"";
    const start = std.mem.indexOf(u8, payload, dev_key) orelse return 0;
    const val_start = start + dev_key.len;
    const val_end = std.mem.indexOfScalarPos(u8, payload, val_start, '"') orelse return 0;
    const len = val_end - val_start;
    if (len > buf.len) return 0;
    @memcpy(buf[0..len], payload[val_start..val_end]);
    return len;
}
