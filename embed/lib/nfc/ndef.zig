//! NDEF message parsing helpers.

const glib = @import("glib");

pub const type_empty: []const u8 = "";
pub const type_text: []const u8 = "T";
pub const type_uri: []const u8 = "U";

pub const Error = error{
    InvalidMessage,
    InvalidRecord,
    InvalidTlv,
    ChunkedRecord,
};

pub const Tnf = enum(u3) {
    empty = 0x00,
    well_known = 0x01,
    media = 0x02,
    absolute_uri = 0x03,
    external = 0x04,
    unknown = 0x05,
    unchanged = 0x06,
    reserved = 0x07,
};

pub const Record = struct {
    message_begin: bool,
    message_end: bool,
    tnf: Tnf,
    type: []const u8,
    id: []const u8 = &.{},
    payload: []const u8,

    pub fn isText(self: Record) bool {
        return self.tnf == .well_known and glib.std.mem.eql(u8, self.type, type_text);
    }

    pub fn isUri(self: Record) bool {
        return self.tnf == .well_known and glib.std.mem.eql(u8, self.type, type_uri);
    }

    pub fn text(self: Record) Error!Text {
        if (!self.isText()) return error.InvalidRecord;
        if (self.payload.len < 1) return error.InvalidRecord;

        const status = self.payload[0];
        const language_len: usize = status & 0x3f;
        if (self.payload.len < 1 + language_len) return error.InvalidRecord;

        return .{
            .utf16 = (status & 0x80) != 0,
            .language = self.payload[1 .. 1 + language_len],
            .value = self.payload[1 + language_len ..],
        };
    }

    pub fn uri(self: Record) Error!Uri {
        if (!self.isUri()) return error.InvalidRecord;
        if (self.payload.len < 1) return error.InvalidRecord;

        return .{
            .prefix = uriPrefix(self.payload[0]),
            .value = self.payload[1..],
        };
    }
};

pub const Text = struct {
    utf16: bool,
    language: []const u8,
    value: []const u8,
};

pub const Uri = struct {
    prefix: []const u8,
    value: []const u8,
};

pub const Iterator = struct {
    message: []const u8,
    offset: usize = 0,
    seen_begin: bool = false,
    finished: bool = false,

    pub fn init(message: []const u8) Iterator {
        return .{ .message = message };
    }

    pub fn next(self: *Iterator) Error!?Record {
        if (self.finished) return null;
        if (self.offset >= self.message.len) {
            if (!self.seen_begin) return null;
            return error.InvalidMessage;
        }

        const header = self.message[self.offset];
        self.offset += 1;

        const message_begin = (header & 0x80) != 0;
        const message_end = (header & 0x40) != 0;
        const chunked = (header & 0x20) != 0;
        const short_record = (header & 0x10) != 0;
        const id_length_present = (header & 0x08) != 0;
        const tnf: Tnf = @enumFromInt(header & 0x07);

        if (chunked) return error.ChunkedRecord;
        if (!self.seen_begin and !message_begin) return error.InvalidMessage;
        if (self.seen_begin and message_begin) return error.InvalidMessage;
        self.seen_begin = true;

        const type_len = try self.readU8();
        const payload_len = if (short_record)
            @as(usize, try self.readU8())
        else
            @as(usize, try self.readU32());
        const id_len = if (id_length_present) @as(usize, try self.readU8()) else 0;

        const record_type = try self.readSlice(type_len);
        const id = try self.readSlice(id_len);
        const payload = try self.readSlice(payload_len);

        if (tnf == .empty and (record_type.len != 0 or id.len != 0 or payload.len != 0)) {
            return error.InvalidRecord;
        }
        if (tnf == .unchanged) return error.InvalidRecord;
        if (message_end) self.finished = true;

        return .{
            .message_begin = message_begin,
            .message_end = message_end,
            .tnf = tnf,
            .type = record_type,
            .id = id,
            .payload = payload,
        };
    }

    fn readU8(self: *Iterator) Error!u8 {
        if (self.offset >= self.message.len) return error.InvalidRecord;
        defer self.offset += 1;
        return self.message[self.offset];
    }

    fn readU32(self: *Iterator) Error!u32 {
        const raw = try self.readSlice(4);
        return (@as(u32, raw[0]) << 24) |
            (@as(u32, raw[1]) << 16) |
            (@as(u32, raw[2]) << 8) |
            @as(u32, raw[3]);
    }

    fn readSlice(self: *Iterator, len: usize) Error![]const u8 {
        if (len > self.message.len -| self.offset) return error.InvalidRecord;
        defer self.offset += len;
        return self.message[self.offset .. self.offset + len];
    }
};

pub fn iterator(message: []const u8) Iterator {
    return Iterator.init(message);
}

pub fn firstRecord(message: []const u8) Error!?Record {
    var iter = iterator(message);
    return try iter.next();
}

pub fn countRecords(message: []const u8) Error!usize {
    var iter = iterator(message);
    var count: usize = 0;
    while (try iter.next()) |_| count += 1;
    return count;
}

pub fn messageFromType2Memory(memory: []const u8) Error![]const u8 {
    if (memory.len < 16) return error.InvalidTlv;
    return messageFromTlv(memory[16..]);
}

pub fn messageFromTlv(tlv: []const u8) Error![]const u8 {
    var offset: usize = 0;
    while (offset < tlv.len) {
        const tag = tlv[offset];
        offset += 1;

        switch (tag) {
            0x00 => {},
            0xfe => return error.InvalidTlv,
            0x03 => {
                const len = try readTlvLen(tlv, &offset);
                if (len > tlv.len -| offset) return error.InvalidTlv;
                return tlv[offset .. offset + len];
            },
            else => {
                const len = try readTlvLen(tlv, &offset);
                if (len > tlv.len -| offset) return error.InvalidTlv;
                offset += len;
            },
        }
    }
    return error.InvalidTlv;
}

fn readTlvLen(tlv: []const u8, offset: *usize) Error!usize {
    if (offset.* >= tlv.len) return error.InvalidTlv;
    const first = tlv[offset.*];
    offset.* += 1;
    if (first != 0xff) return first;

    if (tlv.len - offset.* < 2) return error.InvalidTlv;
    const len = (@as(u16, tlv[offset.*]) << 8) | @as(u16, tlv[offset.* + 1]);
    offset.* += 2;
    return len;
}

pub fn uriPrefix(code: u8) []const u8 {
    return switch (code) {
        0x00 => "",
        0x01 => "http://www.",
        0x02 => "https://www.",
        0x03 => "http://",
        0x04 => "https://",
        0x05 => "tel:",
        0x06 => "mailto:",
        0x07 => "ftp://anonymous:anonymous@",
        0x08 => "ftp://ftp.",
        0x09 => "ftps://",
        0x0a => "sftp://",
        0x0b => "smb://",
        0x0c => "nfs://",
        0x0d => "ftp://",
        0x0e => "dav://",
        0x0f => "news:",
        0x10 => "telnet://",
        0x11 => "imap:",
        0x12 => "rtsp://",
        0x13 => "urn:",
        0x14 => "pop:",
        0x15 => "sip:",
        0x16 => "sips:",
        0x17 => "tftp:",
        0x18 => "btspp://",
        0x19 => "btl2cap://",
        0x1a => "btgoep://",
        0x1b => "tcpobex://",
        0x1c => "irdaobex://",
        0x1d => "file://",
        0x1e => "urn:epc:id:",
        0x1f => "urn:epc:tag:",
        0x20 => "urn:epc:pat:",
        0x21 => "urn:epc:raw:",
        0x22 => "urn:epc:",
        0x23 => "urn:nfc:",
        else => "",
    };
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn parsesWellKnownTextRecord() !void {
            const message = [_]u8{
                0xd1, 0x01, 0x08, 'T', 0x02, 'e', 'n', 'h', 'e', 'l', 'l', 'o',
            };

            var iter = iterator(&message);
            const record = (try iter.next()) orelse return error.MissingRecord;
            try grt.std.testing.expect(record.message_begin);
            try grt.std.testing.expect(record.message_end);
            try grt.std.testing.expectEqual(Tnf.well_known, record.tnf);
            try grt.std.testing.expect(record.isText());

            const text = try record.text();
            try grt.std.testing.expect(!text.utf16);
            try grt.std.testing.expectEqualSlices(u8, "en", text.language);
            try grt.std.testing.expectEqualSlices(u8, "hello", text.value);
            try grt.std.testing.expectEqual(@as(?Record, null), try iter.next());
        }

        fn parsesWellKnownUriRecord() !void {
            const message = [_]u8{
                0xd1, 0x01, 0x0c, 'U', 0x04, 'g', 'i', 'z', 'c', 'l', 'a', 'w', '.', 'c', 'o', 'm',
            };

            const record = (try firstRecord(&message)) orelse return error.MissingRecord;
            try grt.std.testing.expect(record.isUri());

            const uri = try record.uri();
            try grt.std.testing.expectEqualSlices(u8, "https://", uri.prefix);
            try grt.std.testing.expectEqualSlices(u8, "gizclaw.com", uri.value);
        }

        fn parsesMultiRecordMessage() !void {
            const message = [_]u8{
                0x91, 0x01, 0x04, 'T', 0x02, 'e', 'n', 'a',
                0x51, 0x01, 0x04, 'T', 0x02, 'e', 'n', 'b',
            };

            try grt.std.testing.expectEqual(@as(usize, 2), try countRecords(&message));
        }

        fn parsesRecordWithIdLength() !void {
            const message = [_]u8{
                0xd9, 0x01, 0x04, 0x02, 'T', 'i', 'd', 0x02, 'e', 'n', 'x',
            };

            const record = (try firstRecord(&message)) orelse return error.MissingRecord;
            try grt.std.testing.expect(record.message_begin);
            try grt.std.testing.expect(record.message_end);
            try grt.std.testing.expectEqual(Tnf.well_known, record.tnf);
            try grt.std.testing.expectEqualSlices(u8, "T", record.type);
            try grt.std.testing.expectEqualSlices(u8, "id", record.id);

            const text = try record.text();
            try grt.std.testing.expectEqualSlices(u8, "en", text.language);
            try grt.std.testing.expectEqualSlices(u8, "x", text.value);
        }

        fn parsesLongPayloadRecord() !void {
            const message = [_]u8{
                0xc1, 0x01, 0x00, 0x00, 0x01, 0x01, 'T',
            } ++ [_]u8{0x00} ** 257;

            const record = (try firstRecord(&message)) orelse return error.MissingRecord;
            try grt.std.testing.expectEqual(@as(usize, 257), record.payload.len);
        }

        fn extractsMessageFromType2Tlv() !void {
            const message = [_]u8{
                0xd1, 0x01, 0x04, 'T', 0x02, 'e', 'n', 'x',
            };
            const memory = [_]u8{0x00} ** 16 ++ [_]u8{ 0x00, 0x03, message.len } ++ message ++ [_]u8{0xfe};

            const parsed = try messageFromType2Memory(&memory);
            try grt.std.testing.expectEqualSlices(u8, &message, parsed);
        }

        fn extractsExtendedLengthTlvAndSkipsOtherTags() !void {
            const message = [_]u8{
                0xd1, 0x01, 0x04, 'T', 0x02, 'e', 'n', 'x',
            };
            const tlv = [_]u8{
                0x00,
                0x01, 0x01, 0xaa,
                0x03, 0xff, 0x00, message.len,
            } ++ message ++ [_]u8{0xfe};

            const parsed = try messageFromTlv(&tlv);
            try grt.std.testing.expectEqualSlices(u8, &message, parsed);
        }

        fn rejectsInvalidRecordPayloads() !void {
            const invalid_text = [_]u8{ 0xd1, 0x01, 0x01, 'T', 0x02 };
            const text_record = (try firstRecord(&invalid_text)) orelse return error.MissingRecord;
            try grt.std.testing.expectError(error.InvalidRecord, text_record.text());

            const invalid_uri = [_]u8{ 0xd1, 0x01, 0x00, 'U' };
            const uri_record = (try firstRecord(&invalid_uri)) orelse return error.MissingRecord;
            try grt.std.testing.expectError(error.InvalidRecord, uri_record.uri());
        }

        fn rejectsInvalidMessages() !void {
            try grt.std.testing.expectError(error.InvalidMessage, countRecords(&.{ 0x51, 0x00, 0x00 }));
            try grt.std.testing.expectError(error.ChunkedRecord, countRecords(&.{ 0xf1, 0x00, 0x00 }));
            try grt.std.testing.expectError(error.InvalidRecord, countRecords(&.{ 0xd6, 0x00, 0x00 }));
            try grt.std.testing.expectError(error.InvalidTlv, messageFromTlv(&.{ 0x03, 0x10, 0x01 }));
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            TestCase.parsesWellKnownTextRecord() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.parsesWellKnownUriRecord() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.parsesMultiRecordMessage() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.parsesRecordWithIdLength() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.parsesLongPayloadRecord() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.extractsMessageFromType2Tlv() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.extractsExtendedLengthTlvAndSkipsOtherTags() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.rejectsInvalidRecordPayloads() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.rejectsInvalidMessages() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: glib.std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return glib.testing.TestRunner.make(Runner).new(&Holder.runner);
}
