//! GATT client — service/characteristic discovery, read, write, subscribe.
//!
//! Generates ATT request PDUs and parses ATT response PDUs.
//! No I/O — the Hci coordinator handles actual transport.

const glib = @import("glib");

const att = @import("../att.zig");

pub const DiscoveredService = struct {
    start_handle: u16,
    end_handle: u16,
    uuid: u16,
};

pub const DiscoveredChar = struct {
    decl_handle: u16,
    value_handle: u16,
    properties: u8,
    uuid: u16,
};

/// Generate a Read By Group Type Request to discover primary services.
pub fn encodeDiscoverServices(buf: []u8, start_handle: u16) []const u8 {
    return att.encodeReadByGroupTypeRequest(buf, start_handle, 0xFFFF, att.UUID.from16(att.PRIMARY_SERVICE_UUID));
}

/// Parse a Read By Group Type Response into discovered services.
pub fn parseDiscoverServicesResponse(data: []const u8, out: []DiscoveredService) usize {
    const pdu = att.decodePdu(data) orelse return 0;
    switch (pdu) {
        .read_by_group_type_response => |resp| {
            if (resp.length == 0) return 0;
            const entry_len: usize = resp.length;
            var count: usize = 0;
            var offset: usize = 0;
            while (offset + entry_len <= resp.data.len and count < out.len) {
                const entry = resp.data[offset..][0..entry_len];
                if (entry_len >= 6) {
                    out[count] = .{
                        .start_handle = glib.std.mem.readInt(u16, entry[0..2], .little),
                        .end_handle = glib.std.mem.readInt(u16, entry[2..4], .little),
                        .uuid = glib.std.mem.readInt(u16, entry[4..6], .little),
                    };
                    count += 1;
                }
                offset += entry_len;
            }
            return count;
        },
        else => return 0,
    }
}

/// Generate a Read By Type Request to discover characteristics.
pub fn encodeDiscoverChars(buf: []u8, start_handle: u16, end_handle: u16) []const u8 {
    return att.encodeReadByTypeRequest(buf, start_handle, end_handle, att.UUID.from16(att.CHARACTERISTIC_UUID));
}

/// Parse a Read By Type Response into discovered characteristics.
pub fn parseDiscoverCharsResponse(data: []const u8, out: []DiscoveredChar) usize {
    const pdu = att.decodePdu(data) orelse return 0;
    switch (pdu) {
        .read_by_type_response => |resp| {
            if (resp.length == 0) return 0;
            const entry_len: usize = resp.length;
            var count: usize = 0;
            var offset: usize = 0;
            while (offset + entry_len <= resp.data.len and count < out.len) {
                const entry = resp.data[offset..][0..entry_len];
                if (entry_len >= 7) {
                    out[count] = .{
                        .decl_handle = glib.std.mem.readInt(u16, entry[0..2], .little),
                        .properties = entry[2],
                        .value_handle = glib.std.mem.readInt(u16, entry[3..5], .little),
                        .uuid = glib.std.mem.readInt(u16, entry[5..7], .little),
                    };
                    count += 1;
                }
                offset += entry_len;
            }
            return count;
        },
        else => return 0,
    }
}

/// Generate a Find Information Request to discover CCCDs.
pub fn encodeFindCccd(buf: []u8, start_handle: u16, end_handle: u16) []const u8 {
    return att.encodeFindInformationRequest(buf, start_handle, end_handle);
}

/// Parse a Find Information Response to locate CCCD handles.
pub fn parseFindCccdResponse(data: []const u8) ?u16 {
    const pdu = att.decodePdu(data) orelse return null;
    switch (pdu) {
        .find_information_response => |resp| {
            if (resp.format != 0x01) return null; // only 16-bit UUIDs
            var offset: usize = 0;
            while (offset + 4 <= resp.data.len) {
                const handle = glib.std.mem.readInt(u16, resp.data[offset..][0..2], .little);
                const uuid = glib.std.mem.readInt(u16, resp.data[offset + 2 ..][0..2], .little);
                if (uuid == att.CCCD_UUID) return handle;
                offset += 4;
            }
            return null;
        },
        else => return null,
    }
}

/// Generate a Read Request.
pub fn encodeRead(buf: []u8, handle: u16) []const u8 {
    return att.encodeReadRequest(buf, handle);
}

/// Parse a Read Response, copy value into out.
pub fn parseReadResponse(data: []const u8, out: []u8) usize {
    const pdu = att.decodePdu(data) orelse return 0;
    switch (pdu) {
        .read_response => |resp| {
            const n = @min(resp.value.len, out.len);
            @memcpy(out[0..n], resp.value[0..n]);
            return n;
        },
        else => return 0,
    }
}

/// Generate a Write Request.
pub fn encodeWrite(buf: []u8, handle: u16, value: []const u8) []const u8 {
    return att.encodeWriteRequest(buf, handle, value);
}

/// Generate a Write Command (no response).
pub fn encodeWriteCommand(buf: []u8, handle: u16, value: []const u8) []const u8 {
    return att.encodeWriteCommand(buf, handle, value);
}

/// Generate a CCCD write to enable notifications.
pub fn encodeSubscribe(buf: []u8, cccd_handle: u16) []const u8 {
    return att.encodeWriteRequest(buf, cccd_handle, &[2]u8{ 0x01, 0x00 });
}

/// Generate a CCCD write to enable indications.
pub fn encodeSubscribeIndications(buf: []u8, cccd_handle: u16) []const u8 {
    return att.encodeWriteRequest(buf, cccd_handle, &[2]u8{ 0x02, 0x00 });
}

/// Generate a CCCD write to disable notifications/indications.
pub fn encodeUnsubscribe(buf: []u8, cccd_handle: u16) []const u8 {
    return att.encodeWriteRequest(buf, cccd_handle, &[2]u8{ 0x00, 0x00 });
}

/// Check if an ATT PDU is an error response for a given request opcode.
pub fn isErrorFor(data: []const u8, request_opcode: u8) ?att.ErrorCode {
    const pdu = att.decodePdu(data) orelse return null;
    switch (pdu) {
        .error_response => |e| {
            if (e.request_opcode == request_opcode) return e.error_code;
            return null;
        },
        else => return null,
    }
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn run() !void {
            {
                var buf: [att.MAX_PDU_LEN]u8 = undefined;
                const req = encodeRead(&buf, 0x0003);
                try grt.std.testing.expectEqual(att.READ_REQUEST, req[0]);

                var resp_buf: [att.MAX_PDU_LEN]u8 = undefined;
                const resp = att.encodeReadResponse(&resp_buf, "hello");

                var out: [64]u8 = undefined;
                const n = parseReadResponse(resp, &out);
                try grt.std.testing.expectEqual(@as(usize, 5), n);
                try grt.std.testing.expectEqualSlices(u8, "hello", out[0..5]);
            }

            {
                var buf: [att.MAX_PDU_LEN]u8 = undefined;

                const sub = encodeSubscribe(&buf, 0x0004);
                try grt.std.testing.expectEqual(att.WRITE_REQUEST, sub[0]);
                try grt.std.testing.expectEqual(@as(u8, 0x01), sub[3]);
                try grt.std.testing.expectEqual(@as(u8, 0x00), sub[4]);

                const unsub = encodeUnsubscribe(&buf, 0x0004);
                try grt.std.testing.expectEqual(@as(u8, 0x00), unsub[3]);
                try grt.std.testing.expectEqual(@as(u8, 0x00), unsub[4]);
            }

            {
                var buf: [att.MAX_PDU_LEN]u8 = undefined;
                const err_pdu = att.encodeErrorResponse(&buf, att.READ_REQUEST, 0x0001, .invalid_handle);
                const code = isErrorFor(err_pdu, att.READ_REQUEST);
                try grt.std.testing.expectEqual(att.ErrorCode.invalid_handle, code.?);

                const wrong = isErrorFor(err_pdu, att.WRITE_REQUEST);
                try grt.std.testing.expectEqual(@as(?att.ErrorCode, null), wrong);
            }
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

            TestCase.run() catch |err| {
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
