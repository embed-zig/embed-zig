const builtin_std = @import("std");
const testing_api = @import("testing");

const block_len = 512;

pub const Error = error{
    TruncatedArchive,
    InvalidHeader,
    InvalidChecksum,
    NameTooLong,
    Unsupported,
};

pub const EntryKind = enum {
    file,
    directory,
    other,
};

pub const Entry = struct {
    name: []const u8,
    prefix: []const u8 = "",
    kind: EntryKind,
    size: usize,
    data: []const u8,
    mode: u32 = 0,

    pub fn path(self: Entry, buf: []u8) Error![]const u8 {
        if (self.prefix.len == 0) return self.name;
        if (buf.len < self.prefix.len + 1 + self.name.len) return error.NameTooLong;
        @memcpy(buf[0..self.prefix.len], self.prefix);
        buf[self.prefix.len] = '/';
        @memcpy(buf[self.prefix.len + 1 ..][0..self.name.len], self.name);
        return buf[0 .. self.prefix.len + 1 + self.name.len];
    }
};

pub const Stats = struct {
    entry_count: usize = 0,
    file_count: usize = 0,
    directory_count: usize = 0,
    other_count: usize = 0,
    file_payload_len: usize = 0,
};

pub const Reader = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn init(data: []const u8) Reader {
        return .{ .data = data };
    }

    pub fn next(self: *Reader) Error!?Entry {
        if (self.pos == self.data.len) return null;
        if (self.pos + block_len > self.data.len) return error.TruncatedArchive;

        const header = self.data[self.pos..][0..block_len];
        if (isZeroBlock(header)) {
            self.pos = self.data.len;
            return null;
        }

        try validateChecksum(header);

        const name = nullTerminated(header[0..100]);
        const prefix = nullTerminated(header[345..500]);
        if (name.len == 0) return error.InvalidHeader;

        const size = try parseOctal(usize, header[124..136]);
        const mode = try parseOctal(u32, header[100..108]);
        const kind = entryKind(header[156]);

        const data_pos = self.pos + block_len;
        if (size > self.data.len - data_pos) return error.TruncatedArchive;
        const data = self.data[data_pos..][0..size];
        const padded_size = paddedLen(size);
        if (padded_size > self.data.len - data_pos) return error.TruncatedArchive;
        self.pos = data_pos + padded_size;

        return .{
            .name = name,
            .prefix = prefix,
            .kind = kind,
            .size = size,
            .data = data,
            .mode = mode,
        };
    }
};

pub fn stats(data: []const u8) Error!Stats {
    var out: Stats = .{};
    var reader = Reader.init(data);
    while (try reader.next()) |entry| {
        out.entry_count += 1;
        switch (entry.kind) {
            .file => {
                out.file_count += 1;
                out.file_payload_len += entry.data.len;
            },
            .directory => out.directory_count += 1,
            .other => out.other_count += 1,
        }
    }
    return out;
}

fn entryKind(typeflag: u8) EntryKind {
    return switch (typeflag) {
        0, '0' => .file,
        '5' => .directory,
        else => .other,
    };
}

fn paddedLen(size: usize) usize {
    const mask: usize = block_len - 1;
    return (size + mask) & ~mask;
}

fn nullTerminated(field: []const u8) []const u8 {
    const end = builtin_std.mem.indexOfScalar(u8, field, 0) orelse field.len;
    return builtin_std.mem.trimRight(u8, field[0..end], " ");
}

fn parseOctal(comptime T: type, field: []const u8) Error!T {
    if (field.len > 0 and (field[0] & 0x80) != 0) return error.Unsupported;

    var value: T = 0;
    var saw_digit = false;
    for (field) |ch| {
        switch (ch) {
            0, ' ' => {
                if (saw_digit) continue;
            },
            '0'...'7' => {
                saw_digit = true;
                value = builtin_std.math.mul(T, value, 8) catch return error.InvalidHeader;
                value = builtin_std.math.add(T, value, @as(T, @intCast(ch - '0'))) catch return error.InvalidHeader;
            },
            else => return error.InvalidHeader,
        }
    }
    return value;
}

fn validateChecksum(header: []const u8) Error!void {
    if (header.len != block_len) return error.InvalidHeader;

    const expected = try parseOctal(u32, header[148..156]);
    var actual: u32 = 0;
    for (header, 0..) |byte, i| {
        actual += if (i >= 148 and i < 156) ' ' else byte;
    }
    if (actual != expected) return error.InvalidChecksum;
}

fn isZeroBlock(block: []const u8) bool {
    for (block) |byte| {
        if (byte != 0) return false;
    }
    return true;
}

pub fn TestRunner(comptime std: type) testing_api.TestRunner {
    const Runner = struct {
        const testing = std.testing;

        pub fn init(self: *@This(), allocator: std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            readsEntries() catch |err| return fail(t, err);
            countsStats() catch |err| return fail(t, err);
            rejectsBadChecksum() catch |err| return fail(t, err);
            return true;
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }

        fn readsEntries() !void {
            const archive = makeTestTar();
            var reader = Reader.init(&archive);

            var path_buf: [128]u8 = undefined;
            const dir = (try reader.next()).?;
            try testing.expectEqual(EntryKind.directory, dir.kind);
            try testing.expectEqualSlices(u8, "h106", try dir.path(&path_buf));

            const startup = (try reader.next()).?;
            try testing.expectEqual(EntryKind.file, startup.kind);
            try testing.expectEqualSlices(u8, "h106/startup/tiga_startup.pixa", try startup.path(&path_buf));
            try testing.expectEqualSlices(u8, "pixa", startup.data);

            const font = (try reader.next()).?;
            try testing.expectEqual(EntryKind.file, font.kind);
            try testing.expectEqualSlices(u8, "h106/fonts/NotoSansSC-Bold.ttf", try font.path(&path_buf));
            try testing.expectEqualSlices(u8, "font", font.data);

            try testing.expectEqual(@as(?Entry, null), try reader.next());
        }

        fn countsStats() !void {
            const archive = makeTestTar();
            const archive_stats = try stats(&archive);
            try testing.expectEqual(@as(usize, 3), archive_stats.entry_count);
            try testing.expectEqual(@as(usize, 2), archive_stats.file_count);
            try testing.expectEqual(@as(usize, 1), archive_stats.directory_count);
            try testing.expectEqual(@as(usize, 0), archive_stats.other_count);
            try testing.expectEqual(@as(usize, 8), archive_stats.file_payload_len);
        }

        fn rejectsBadChecksum() !void {
            var archive = makeTestTar();
            archive[0] = 'x';
            var reader = Reader.init(&archive);
            try testing.expectError(error.InvalidChecksum, reader.next());
        }

        fn fail(t: *testing_api.T, err: anyerror) bool {
            t.logFatal(@errorName(err));
            return false;
        }

        fn makeTestTar() [block_len * 7]u8 {
            var out = [_]u8{0} ** (block_len * 7);
            writeHeader(out[0..block_len], "h106", '5', 0, 0o755);
            writeHeader(out[block_len..][0..block_len], "startup/tiga_startup.pixa", '0', 4, 0o644);
            @memcpy(out[block_len * 2 ..][0..4], "pixa");
            writeHeader(out[block_len * 3 ..][0..block_len], "fonts/NotoSansSC-Bold.ttf", '0', 4, 0o644);
            @memcpy(out[block_len * 4 ..][0..4], "font");
            @memcpy(out[block_len + 345 ..][0..4], "h106");
            @memcpy(out[block_len * 3 + 345 ..][0..4], "h106");
            refreshChecksum(out[block_len..][0..block_len]);
            refreshChecksum(out[block_len * 3 ..][0..block_len]);
            return out;
        }

        fn writeHeader(header: []u8, name: []const u8, typeflag: u8, size: usize, mode: u32) void {
            @memset(header, 0);
            @memcpy(header[0..name.len], name);
            writeOctal(header[100..108], mode);
            writeOctal(header[108..116], 0);
            writeOctal(header[116..124], 0);
            writeOctal(header[124..136], size);
            writeOctal(header[136..148], 0);
            @memset(header[148..156], ' ');
            header[156] = typeflag;
            @memcpy(header[257..263], "ustar\x00");
            @memcpy(header[263..265], "00");
            refreshChecksum(header);
        }

        fn refreshChecksum(header: []u8) void {
            @memset(header[148..156], ' ');
            var sum: u32 = 0;
            for (header) |byte| sum += byte;
            writeOctal(header[148..156], sum);
        }

        fn writeOctal(field: []u8, value: anytype) void {
            @memset(field, 0);
            var tmp: [32]u8 = undefined;
            const text = builtin_std.fmt.bufPrint(&tmp, "{o}", .{value}) catch unreachable;
            const start = field.len - 1 - text.len;
            @memset(field[0..start], '0');
            @memcpy(field[start..][0..text.len], text);
            field[field.len - 1] = 0;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}
