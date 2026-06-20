const std = @import("std");
const gstd = @import("gstd");

const max_entries = 256;
const max_line_len = 1024;

pub const CopiedEntry = struct {
    seq: u64 = 0,
    line: [max_line_len]u8 = [_]u8{0} ** max_line_len,
    len: usize = 0,

    pub fn bytes(self: *const @This()) []const u8 {
        return self.line[0..self.len];
    }
};

const Entry = struct {
    seq: u64 = 0,
    line: [max_line_len]u8 = [_]u8{0} ** max_line_len,
    len: usize = 0,
};

var mutex: gstd.runtime.sync.Mutex = .{};
var entries: [max_entries]Entry = [_]Entry{.{}} ** max_entries;
var next_seq: u64 = 1;

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    std.log.defaultLog(level, scope, format, args);
    append(level.asText(), @tagName(scope), format, args);
}

pub fn append(
    comptime level: []const u8,
    comptime scope: []const u8,
    comptime format: []const u8,
    args: anytype,
) void {
    var line_buf: [max_line_len]u8 = undefined;
    var out = std.Io.Writer.fixed(&line_buf);
    out.print("[{s}] ({s}) " ++ format, .{ level, scope } ++ args) catch {};
    const line = out.buffered();

    mutex.lock();
    defer mutex.unlock();

    const seq = next_seq;
    next_seq +%= 1;

    const slot = &entries[seq % max_entries];
    slot.seq = seq;
    slot.len = @min(line.len, slot.line.len);
    @memcpy(slot.line[0..slot.len], line[0..slot.len]);
}

pub fn copySince(after_seq: u64, out: []CopiedEntry) usize {
    mutex.lock();
    defer mutex.unlock();

    const current_next = next_seq;
    const oldest_seq = if (current_next > max_entries) current_next - max_entries else 1;
    var seq = @max(after_seq +% 1, oldest_seq);
    var count: usize = 0;
    while (seq < current_next and count < out.len) : (seq += 1) {
        const slot = entries[seq % max_entries];
        if (slot.seq != seq) continue;
        out[count].seq = slot.seq;
        out[count].len = slot.len;
        @memcpy(out[count].line[0..slot.len], slot.line[0..slot.len]);
        count += 1;
    }
    return count;
}
