//! `audio/ogg/Sync.zig` owns the pure Zig rewrite of upstream
//! `ogg_sync_state` buffer management and page sync logic.

const embed = @import("embed");
const crc = @import("crc.zig");
const Page = @import("Page.zig");
const Packet = @import("Packet.zig");
const Stream = @import("Stream.zig");
const testing_api = @import("testing");

const Self = @This();

const page_header_limit = Page.minimum_header_len + 255;

pub const Error = embed.mem.Allocator.Error || error{
    InvalidState,
    Overflow,
    InvalidWrite,
};

pub const PageSeekResult = union(enum) {
    need_more,
    skipped: usize,
    page: Page,
};

pub const PageOutResult = union(enum) {
    need_more,
    hole,
    page: Page,
};

allocator: ?embed.mem.Allocator = null,
data: ?[]u8 = null,
fill: usize = 0,
returned: usize = 0,

unsynced: bool = false,
headerbytes: usize = 0,
bodybytes: usize = 0,
initialized: bool = false,

pub fn init(allocator: embed.mem.Allocator) Self {
    return .{
        .allocator = allocator,
        .initialized = true,
    };
}

pub fn deinit(self: *Self) void {
    if (self.data) |data| {
        self.allocator.?.free(data);
    }
    self.* = .{};
}

pub fn check(self: *const Self) bool {
    return self.initialized;
}

pub fn reset(self: *Self) Error!void {
    try self.ensureReady();

    self.fill = 0;
    self.returned = 0;
    self.unsynced = false;
    self.headerbytes = 0;
    self.bodybytes = 0;
}

// The returned writable slice aliases internal storage and is invalidated by the
// next mutating call on the same sync state.
pub fn buffer(self: *Self, size: usize) Error![]u8 {
    try self.ensureReady();
    self.compactReturned();

    const current_storage = if (self.data) |data| data.len else 0;
    if (size > current_storage -| self.fill) {
        var new_size = checkedAdd(size, self.fill) orelse return error.Overflow;
        new_size = checkedAdd(new_size, 4096) orelse return error.Overflow;

        if (self.data) |data| {
            self.data = try self.allocator.?.realloc(data, new_size);
        } else {
            self.data = try self.allocator.?.alloc(u8, new_size);
        }
    }

    return self.data.?[self.fill .. self.fill + size];
}

pub fn wrote(self: *Self, bytes: usize) Error!void {
    try self.ensureReady();

    const storage = if (self.data) |data| data.len else 0;
    if (self.fill + bytes > storage) return error.InvalidWrite;
    self.fill += bytes;
}

pub fn pageSeek(self: *Self) Error!PageSeekResult {
    try self.ensureReady();

    const data = self.data orelse return .need_more;
    const page_start = self.returned;
    const bytes = self.fill - self.returned;
    if (bytes == 0) return .need_more;

    const page = data[page_start .. page_start + bytes];

    if (self.headerbytes == 0) {
        if (bytes < Page.minimum_header_len) return .need_more;
        if (!hasCapturePattern(page)) {
            return self.syncFail(page);
        }

        const headerbytes = @as(usize, page[26]) + Page.minimum_header_len;
        if (bytes < headerbytes) return .need_more;

        var bodybytes: usize = 0;
        for (page[Page.minimum_header_len..headerbytes]) |segment_len| {
            bodybytes += segment_len;
        }
        self.headerbytes = headerbytes;
        self.bodybytes = bodybytes;
    }

    if (self.bodybytes + self.headerbytes > bytes) return .need_more;

    const header = page[0..self.headerbytes];
    const body = page[self.headerbytes .. self.headerbytes + self.bodybytes];
    if (!verifyChecksum(header, body)) {
        return self.syncFail(page);
    }

    const full_page_len = self.headerbytes + self.bodybytes;
    self.unsynced = false;
    self.returned += full_page_len;
    self.headerbytes = 0;
    self.bodybytes = 0;

    return .{ .page = Page.init(data[page_start .. page_start + header.len], data[page_start + header.len .. page_start + full_page_len]) };
}

pub fn pageOut(self: *Self) Error!PageOutResult {
    try self.ensureReady();

    while (true) {
        switch (try self.pageSeek()) {
            .page => |page| return .{ .page = page },
            .need_more => return .need_more,
            .skipped => {
                if (!self.unsynced) {
                    self.unsynced = true;
                    return .hole;
                }
            },
        }
    }
}

fn syncFail(self: *Self, page: []const u8) PageSeekResult {
    self.headerbytes = 0;
    self.bodybytes = 0;

    const relative = indexOfByte(page[1..], 'O') orelse page.len - 1;
    const skipped = relative + 1;

    self.returned += skipped;
    return .{ .skipped = skipped };
}

fn compactReturned(self: *Self) void {
    if (self.returned == 0) return;
    const data = self.data orelse return;

    self.fill -= self.returned;
    if (self.fill > 0) {
        @memmove(data[0..self.fill], data[self.returned .. self.returned + self.fill]);
    }
    self.returned = 0;
}

fn ensureReady(self: *const Self) Error!void {
    if (!self.initialized) return error.InvalidState;
}

fn verifyChecksum(header: []const u8, body: []const u8) bool {
    if (header.len < crc.checksum_field_offset + crc.checksum_field_len) return false;

    var header_copy = [_]u8{0} ** page_header_limit;
    if (header.len > header_copy.len) return false;

    @memcpy(header_copy[0..header.len], header);
    @memset(header_copy[crc.checksum_field_offset .. crc.checksum_field_offset + crc.checksum_field_len], 0);

    const expected = crc.encodeChecksum(crc.pageChecksum(header_copy[0..header.len], body));
    return bytesEqual(expected[0..], header[crc.checksum_field_offset .. crc.checksum_field_offset + crc.checksum_field_len]);
}

fn checkedAdd(a: usize, b: usize) ?usize {
    const result = @addWithOverflow(a, b);
    if (result[1] != 0) return null;
    return result[0];
}

fn hasCapturePattern(bytes: []const u8) bool {
    if (bytes.len < 4) return false;
    return bytes[0] == 'O' and bytes[1] == 'g' and bytes[2] == 'g' and bytes[3] == 'S';
}

fn indexOfByte(bytes: []const u8, needle: u8) ?usize {
    for (bytes, 0..) |byte, index| {
        if (byte == needle) return index;
    }
    return null;
}

fn bytesEqual(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| {
        if (a != b) return false;
    }
    return true;
}

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    const TestCase = struct {
        fn testPageOutAssemblesBufferedChunks(allocator: lib.mem.Allocator) !void {
            const testing = lib.testing;

            var encoder = try Stream.init(allocator, 1234);
            defer encoder.deinit();

            var sync = init(allocator);
            defer sync.deinit();

            const packet = Packet.initBorrowed("hello sync", .{ .bos = true, .eos = true, .granulepos = 77 });
            try encoder.packetIn(&packet);
            const page = (try encoder.flush()).?;

            var bytes = [_]u8{0} ** 128;
            const total = appendPageBytes(bytes[0..], page.header, page.body);

            const first_chunk = try sync.buffer(8);
            @memcpy(first_chunk, bytes[0..8]);
            try sync.wrote(8);
            switch (try sync.pageOut()) {
                .need_more => {},
                else => return error.TestUnexpectedResult,
            }

            const second_chunk = try sync.buffer(total - 8);
            @memcpy(second_chunk, bytes[8..total]);
            try sync.wrote(total - 8);

            switch (try sync.pageOut()) {
                .page => |synced_page| {
                    try testing.expectEqual(@as(u32, 1234), try synced_page.serialNo());
                    try testing.expectEqual(@as(u32, 0), try synced_page.pageNo());
                    try testing.expectEqualSlices(u8, "hello sync", synced_page.body);
                },
                else => return error.TestUnexpectedResult,
            }
        }

        fn testPageSeekReportsSkippedBytesForBadCapturePattern(allocator: lib.mem.Allocator) !void {
            const testing = lib.testing;

            var sync = init(allocator);
            defer sync.deinit();

            const writable = try sync.buffer(32);
            @memset(writable, 'x');
            try sync.wrote(32);

            switch (try sync.pageSeek()) {
                .skipped => |count| try testing.expectEqual(@as(usize, 32), count),
                else => return error.TestUnexpectedResult,
            }
        }

        fn testPageOutReturnsHoleAfterChecksumFailure(allocator: lib.mem.Allocator) !void {
            const testing = lib.testing;

            var encoder = try Stream.init(allocator, 9);
            defer encoder.deinit();

            var sync = init(allocator);
            defer sync.deinit();

            const packet0 = Packet.initBorrowed("good-0", .{ .bos = true });
            try encoder.packetIn(&packet0);
            const page0 = (try encoder.flush()).?;

            const packet1 = Packet.initBorrowed("good-1", .{});
            try encoder.packetIn(&packet1);
            const page1 = (try encoder.flush()).?;

            var all = [_]u8{0} ** 512;
            const page0_len = appendPageBytes(all[0..], page0.header, page0.body);
            const page1_len = appendPageBytes(all[page0_len..], page1.header, page1.body);
            all[22] ^= 0xff;

            const writable = try sync.buffer(page0_len + page1_len);
            @memcpy(writable, all[0 .. page0_len + page1_len]);
            try sync.wrote(page0_len + page1_len);

            switch (try sync.pageOut()) {
                .hole => {},
                else => return error.TestUnexpectedResult,
            }
            switch (try sync.pageOut()) {
                .page => |synced_page| try testing.expectEqualSlices(u8, "good-1", synced_page.body),
                else => return error.TestUnexpectedResult,
            }
        }

        fn testResetClearsSyncBookkeeping(allocator: lib.mem.Allocator) !void {
            const testing = lib.testing;

            var sync = init(allocator);
            defer sync.deinit();

            const writable = try sync.buffer(4);
            @memcpy(writable, "OggS");
            try sync.wrote(4);
            try sync.reset();

            try testing.expectEqual(@as(usize, 0), sync.fill);
            try testing.expectEqual(@as(usize, 0), sync.returned);
            try testing.expect(!sync.unsynced);
            try testing.expectEqual(@as(usize, 0), sync.headerbytes);
            try testing.expectEqual(@as(usize, 0), sync.bodybytes);
        }

        fn appendPageBytes(dest: []u8, header: []const u8, body: []const u8) usize {
            @memcpy(dest[0..header.len], header);
            @memcpy(dest[header.len .. header.len + body.len], body);
            return header.len + body.len;
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;

            TestCase.testPageOutAssemblesBufferedChunks(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.testPageSeekReportsSkippedBytesForBadCapturePattern(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.testPageOutReturnsHoleAfterChecksumFailure(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.testResetClearsSyncBookkeeping(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: lib.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}
