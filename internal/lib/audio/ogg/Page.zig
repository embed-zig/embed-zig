//! `audio/ogg/Page.zig` owns the pure Zig rewrite of upstream `ogg_page`
//! metadata helpers and public checksum application behavior.

const crc = @import("crc.zig");
const testing_api = @import("testing");

const Self = @This();

pub const minimum_header_len: usize = 27;

pub const Error = error{
    InvalidHeader,
};

header: []u8,
body: []const u8,

pub fn init(header: []u8, body: []const u8) Self {
    return .{
        .header = header,
        .body = body,
    };
}

pub fn version(self: *const Self) Error!u8 {
    return self.headerByte(4);
}

pub fn continued(self: *const Self) Error!bool {
    return ((try self.headerByte(5)) & 0x01) != 0;
}

pub fn bos(self: *const Self) Error!bool {
    return ((try self.headerByte(5)) & 0x02) != 0;
}

pub fn eos(self: *const Self) Error!bool {
    return ((try self.headerByte(5)) & 0x04) != 0;
}

pub fn granulePos(self: *const Self) Error!i64 {
    return @bitCast(try self.readU64At(6));
}

pub fn serialNo(self: *const Self) Error!u32 {
    return self.readU32At(14);
}

pub fn pageNo(self: *const Self) Error!u32 {
    return self.readU32At(18);
}

pub fn packetCount(self: *const Self) Error!usize {
    const segment_count = try self.segmentCount();
    const header = try self.requireHeaderLen(minimum_header_len + segment_count);

    var count: usize = 0;
    for (header[minimum_header_len .. minimum_header_len + segment_count]) |lacing_value| {
        if (lacing_value < 255) count += 1;
    }
    return count;
}

pub fn checksum(self: *const Self) Error!u32 {
    return self.readU32At(crc.checksum_field_offset);
}

pub fn setChecksum(self: *Self) Error!void {
    const header = try self.requireHeaderLen(crc.checksum_field_offset + crc.checksum_field_len);

    @memset(header[crc.checksum_field_offset .. crc.checksum_field_offset + crc.checksum_field_len], 0);

    const checksum_bytes = crc.encodeChecksum(crc.pageChecksum(header, self.body));
    @memcpy(
        header[crc.checksum_field_offset .. crc.checksum_field_offset + crc.checksum_field_len],
        checksum_bytes[0..],
    );
}

fn segmentCount(self: *const Self) Error!usize {
    return @as(usize, try self.headerByte(26));
}

fn headerByte(self: *const Self, index: usize) Error!u8 {
    const header = try self.requireHeaderLen(index + 1);
    return header[index];
}

fn requireHeaderLen(self: *const Self, len: usize) Error![]u8 {
    if (self.header.len < len) return error.InvalidHeader;
    return self.header;
}

fn readU32At(self: *const Self, index: usize) Error!u32 {
    const header = try self.requireHeaderLen(index + 4);
    return @as(u32, header[index]) |
        (@as(u32, header[index + 1]) << 8) |
        (@as(u32, header[index + 2]) << 16) |
        (@as(u32, header[index + 3]) << 24);
}

fn readU64At(self: *const Self, index: usize) Error!u64 {
    const header = try self.requireHeaderLen(index + 8);
    return @as(u64, header[index]) |
        (@as(u64, header[index + 1]) << 8) |
        (@as(u64, header[index + 2]) << 16) |
        (@as(u64, header[index + 3]) << 24) |
        (@as(u64, header[index + 4]) << 32) |
        (@as(u64, header[index + 5]) << 40) |
        (@as(u64, header[index + 6]) << 48) |
        (@as(u64, header[index + 7]) << 56);
}

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    const TestCase = struct {
        fn testMetadataReadersExposeHeaderFields() !void {
            const testing = lib.testing;

            var header = [_]u8{
                0x4f, 0x67, 0x67, 0x53, 0x00, 0x07, 0x08, 0x07,
                0x06, 0x05, 0x04, 0x03, 0x02, 0x01, 0x11, 0x22,
                0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x00, 0x00,
                0x00, 0x00, 0x05, 0xff, 0x0a, 0xff, 0x00, 0x01,
            };

            var page = init(header[0..], &.{});

            try testing.expectEqual(@as(u8, 0), try page.version());
            try testing.expect(try page.continued());
            try testing.expect(try page.bos());
            try testing.expect(try page.eos());
            try testing.expectEqual(@as(i64, 0x0102030405060708), try page.granulePos());
            try testing.expectEqual(@as(u32, 0x44332211), try page.serialNo());
            try testing.expectEqual(@as(u32, 0x88776655), try page.pageNo());
            try testing.expectEqual(@as(usize, 3), try page.packetCount());
        }

        fn testSetChecksumRewritesChecksumField() !void {
            const testing = lib.testing;

            var header = [_]u8{
                0x4f, 0x67, 0x67, 0x53, 0x00, 0x02, 0x01, 0x02,
                0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x13, 0x37,
                0x42, 0x24, 0x10, 0x00, 0x00, 0x00, 0xaa, 0xbb,
                0xcc, 0xdd, 0x03, 0xff, 0x10, 0x01,
            };
            const body = [_]u8{ 0xde, 0xad, 0xbe, 0xef, 0x00, 0x11, 0x22, 0x33, 0x44 };

            var expected_header = header;
            @memset(expected_header[crc.checksum_field_offset .. crc.checksum_field_offset + crc.checksum_field_len], 0);
            const expected_crc = crc.pageChecksum(expected_header[0..], body[0..]);
            const expected_bytes = crc.encodeChecksum(expected_crc);

            var page = init(header[0..], body[0..]);
            try page.setChecksum();

            try testing.expectEqual(expected_crc, try page.checksum());
            try testing.expectEqualSlices(
                u8,
                expected_bytes[0..],
                header[crc.checksum_field_offset .. crc.checksum_field_offset + crc.checksum_field_len],
            );
        }

        fn testShortHeadersAreRejected() !void {
            const testing = lib.testing;

            var short_header = [_]u8{ 0x4f, 0x67, 0x67 };
            var page = init(short_header[0..], &.{});
            try testing.expectError(error.InvalidHeader, page.version());
            try testing.expectError(error.InvalidHeader, page.packetCount());
            try testing.expectError(error.InvalidHeader, page.setChecksum());
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            TestCase.testMetadataReadersExposeHeaderFields() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.testSetChecksumRewritesChecksumField() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.testShortHeadersAreRejected() catch |err| {
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
