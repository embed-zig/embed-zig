//! **DCE** (Data Circuit-terminating Equipment) — modem side for **tests and mocks**.
//!
//! Stateless **longest-prefix** dispatch: one logical command line (no CR/LF) → bytes to send
//! back toward the DTE (include your own `\r\n` in the reply). No `Transport` here; a loopback
//! harness feeds lines from the DTE write path and appends replies to the DTE read path (see
//! `lib/at/README.md`).

/// Handler writes the **full** modem reply into `out` and returns the byte count.
pub const RespondFn = *const fn (ctx: ?*anyopaque, line: []const u8, out: []u8) error{OutTooSmall}!usize;

pub const CommandEntry = struct {
    /// Matched when `trimAscii(line)` starts with `prefix`. **Longest** matching prefix wins.
    prefix: []const u8,
    ctx: ?*anyopaque = null,
    respond: RespondFn,
};

pub const HandleLineOptions = struct {
    /// When no `prefix` matches, call this instead of returning `error.NoMatchingPrefix`.
    default_ctx: ?*anyopaque = null,
    default_respond: ?RespondFn = null,
};

pub const HandleLineError = error{
    OutTooSmall,
    NoMatchingPrefix,
};

fn trimAscii(slice: []const u8) []const u8 {
    var s: usize = 0;
    var e = slice.len;
    while (s < e and (slice[s] == ' ' or slice[s] == '\t')) s += 1;
    while (e > s and (slice[e - 1] == ' ' or slice[e - 1] == '\t')) e -= 1;
    return slice[s..e];
}

fn startsWith(haystack: []const u8, prefix: []const u8) bool {
    if (haystack.len < prefix.len) return false;
    var i: usize = 0;
    while (i < prefix.len) : (i += 1) {
        if (haystack[i] != prefix[i]) return false;
    }
    return true;
}

/// Dispatch one **command line** from the DTE (terminators already stripped). Replies are written
/// into `out` (typically ASCII including `\r\n` per line).
pub fn handleLine(
    entries: []const CommandEntry,
    line: []const u8,
    out: []u8,
    opt: HandleLineOptions,
) HandleLineError!usize {
    const t = trimAscii(line);
    var best_i: ?usize = null;
    var best_len: usize = 0;

    for (entries, 0..) |e, i| {
        if (startsWith(t, e.prefix) and e.prefix.len >= best_len) {
            best_len = e.prefix.len;
            best_i = i;
        }
    }

    if (best_i) |idx| {
        const e = entries[idx];
        return e.respond(e.ctx, t, out);
    }

    if (opt.default_respond) |def| {
        return def(opt.default_ctx, t, out);
    }
    return error.NoMatchingPrefix;
}

/// Copy `text` into `out` (common canned responses, e.g. `"OK\r\n"`).
pub fn respondCopy(_: ?*anyopaque, _: []const u8, o: []u8, comptime text: []const u8) error{OutTooSmall}!usize {
    if (o.len < text.len) return error.OutTooSmall;
    @memcpy(o[0..text.len], text);
    return text.len;
}

test "at/unit_tests/Dce/longest_prefix" {
    const std = @import("std");
    const testing = std.testing;

    const Handlers = struct {
        fn at(_: ?*anyopaque, _: []const u8, o: []u8) error{OutTooSmall}!usize {
            return respondCopy(null, "", o, "OK\r\n");
        }
        fn csq(_: ?*anyopaque, _: []const u8, o: []u8) error{OutTooSmall}!usize {
            const msg = "+CSQ: 1,1\r\nOK\r\n";
            if (o.len < msg.len) return error.OutTooSmall;
            @memcpy(o[0..msg.len], msg);
            return msg.len;
        }
    };

    const table = [_]CommandEntry{
        .{ .prefix = "AT", .ctx = null, .respond = Handlers.at },
        .{ .prefix = "AT+CSQ", .ctx = null, .respond = Handlers.csq },
    };

    var buf: [64]u8 = undefined;
    const n = try handleLine(&table, "AT+CSQ", &buf, .{});
    try testing.expectEqualStrings("+CSQ: 1,1\r\nOK\r\n", buf[0..n]);

    const n2 = try handleLine(&table, "AT", &buf, .{});
    try testing.expectEqualStrings("OK\r\n", buf[0..n2]);
}

test "at/unit_tests/Dce/no_match_default" {
    const std = @import("std");
    const testing = std.testing;

    const Def = struct {
        fn f(_: ?*anyopaque, _: []const u8, o: []u8) error{OutTooSmall}!usize {
            return respondCopy(null, "", o, "ERROR\r\n");
        }
    };

    // Only `AT+CSQ` is implemented; `AT+UNKNOWN` must not match prefix `AT+CSQ`.
    const table = [_]CommandEntry{
        .{ .prefix = "AT+CSQ", .ctx = null, .respond = struct {
            fn r(_: ?*anyopaque, _: []const u8, o: []u8) error{OutTooSmall}!usize {
                return respondCopy(null, "", o, "OK\r\n");
            }
        }.r },
    };

    var buf: [32]u8 = undefined;
    try testing.expectError(error.NoMatchingPrefix, handleLine(&table, "AT+UNKNOWN", &buf, .{}));

    const n = try handleLine(&table, "AT+UNKNOWN", &buf, .{
        .default_respond = Def.f,
    });
    try testing.expectEqualStrings("ERROR\r\n", buf[0..n]);
}

test "at/unit_tests/Dce/out_too_small" {
    const std = @import("std");
    const testing = std.testing;

    const table = [_]CommandEntry{
        .{ .prefix = "AT", .ctx = null, .respond = struct {
            fn r(_: ?*anyopaque, _: []const u8, o: []u8) error{OutTooSmall}!usize {
                return respondCopy(null, "", o, "OK\r\n");
            }
        }.r },
    };

    var buf: [2]u8 = undefined;
    try testing.expectError(error.OutTooSmall, handleLine(&table, "AT", &buf, .{}));
}
