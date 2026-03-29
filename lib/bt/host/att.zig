//! Attribute Protocol codec (Bluetooth Core Spec Vol 3 Part F).
//!
//! Pure stateless codec — encode/decode ATT PDUs, UUID handling.
//! No I/O, no state.

const std = @import("std");

// --- Constants ---

pub const DEFAULT_MTU: u16 = 23;
pub const MAX_MTU: u16 = 517;
pub const MAX_PDU_LEN: usize = MAX_MTU;

// --- Opcodes (Vol 3 Part F 3.4) ---

pub const ERROR_RESPONSE: u8 = 0x01;
pub const EXCHANGE_MTU_REQUEST: u8 = 0x02;
pub const EXCHANGE_MTU_RESPONSE: u8 = 0x03;
pub const FIND_INFORMATION_REQUEST: u8 = 0x04;
pub const FIND_INFORMATION_RESPONSE: u8 = 0x05;
pub const FIND_BY_TYPE_VALUE_REQUEST: u8 = 0x06;
pub const FIND_BY_TYPE_VALUE_RESPONSE: u8 = 0x07;
pub const READ_BY_TYPE_REQUEST: u8 = 0x08;
pub const READ_BY_TYPE_RESPONSE: u8 = 0x09;
pub const READ_REQUEST: u8 = 0x0A;
pub const READ_RESPONSE: u8 = 0x0B;
pub const READ_BLOB_REQUEST: u8 = 0x0C;
pub const READ_BLOB_RESPONSE: u8 = 0x0D;
pub const WRITE_REQUEST: u8 = 0x12;
pub const WRITE_RESPONSE: u8 = 0x13;
pub const WRITE_COMMAND: u8 = 0x52;
pub const HANDLE_VALUE_NOTIFICATION: u8 = 0x1B;
pub const HANDLE_VALUE_INDICATION: u8 = 0x1D;
pub const HANDLE_VALUE_CONFIRMATION: u8 = 0x1E;
pub const READ_BY_GROUP_TYPE_REQUEST: u8 = 0x10;
pub const READ_BY_GROUP_TYPE_RESPONSE: u8 = 0x11;
pub const PREPARE_WRITE_REQUEST: u8 = 0x16;
pub const PREPARE_WRITE_RESPONSE: u8 = 0x17;
pub const EXECUTE_WRITE_REQUEST: u8 = 0x18;
pub const EXECUTE_WRITE_RESPONSE: u8 = 0x19;

// --- Error codes (Vol 3 Part F 3.4.1.1) ---

pub const ErrorCode = enum(u8) {
    invalid_handle = 0x01,
    read_not_permitted = 0x02,
    write_not_permitted = 0x03,
    invalid_pdu = 0x04,
    insufficient_authentication = 0x05,
    request_not_supported = 0x06,
    invalid_offset = 0x07,
    insufficient_authorization = 0x08,
    prepare_queue_full = 0x09,
    attribute_not_found = 0x0A,
    attribute_not_long = 0x0B,
    insufficient_encryption_key_size = 0x0C,
    invalid_attribute_value_length = 0x0D,
    unlikely_error = 0x0E,
    insufficient_encryption = 0x0F,
    unsupported_group_type = 0x10,
    insufficient_resources = 0x11,
    _,
};

// --- UUID ---

pub const UUID = union(enum) {
    uuid16: u16,
    uuid128: [16]u8,

    pub fn from16(v: u16) UUID {
        return .{ .uuid16 = v };
    }

    pub fn from128(v: [16]u8) UUID {
        return .{ .uuid128 = v };
    }

    pub fn byteLen(self: UUID) usize {
        return switch (self) {
            .uuid16 => 2,
            .uuid128 => 16,
        };
    }

    pub fn eql(self: UUID, other: UUID) bool {
        return switch (self) {
            .uuid16 => |a| switch (other) {
                .uuid16 => |b| a == b,
                .uuid128 => false,
            },
            .uuid128 => |a| switch (other) {
                .uuid128 => |b| std.mem.eql(u8, &a, &b),
                .uuid16 => false,
            },
        };
    }

    pub fn writeTo(self: UUID, buf: []u8) usize {
        switch (self) {
            .uuid16 => |v| {
                std.debug.assert(buf.len >= 2);
                std.mem.writeInt(u16, buf[0..2], v, .little);
                return 2;
            },
            .uuid128 => |v| {
                std.debug.assert(buf.len >= 16);
                @memcpy(buf[0..16], &v);
                return 16;
            },
        }
    }

    pub fn readFrom(data: []const u8, len: usize) ?UUID {
        if (len == 2 and data.len >= 2) {
            return .{ .uuid16 = std.mem.readInt(u16, data[0..2], .little) };
        } else if (len == 16 and data.len >= 16) {
            return .{ .uuid128 = data[0..16].* };
        }
        return null;
    }
};

// --- Well-known UUIDs (Vol 3 Part B) ---

pub const PRIMARY_SERVICE_UUID: u16 = 0x2800;
pub const SECONDARY_SERVICE_UUID: u16 = 0x2801;
pub const INCLUDE_UUID: u16 = 0x2802;
pub const CHARACTERISTIC_UUID: u16 = 0x2803;
pub const CCCD_UUID: u16 = 0x2902;

// --- Decoded PDU ---

pub const Pdu = union(enum) {
    error_response: ErrorResponse,
    exchange_mtu_request: ExchangeMtuRequest,
    exchange_mtu_response: ExchangeMtuResponse,
    read_by_group_type_request: ReadByGroupTypeRequest,
    read_by_group_type_response: ReadByGroupTypeResponse,
    read_by_type_request: ReadByTypeRequest,
    read_by_type_response: ReadByTypeResponse,
    find_information_request: FindInformationRequest,
    find_information_response: FindInformationResponse,
    read_request: ReadRequest,
    read_response: ReadResponse,
    read_blob_request: ReadBlobRequest,
    write_request: WriteRequest,
    write_command: WriteCommand,
    write_response: void,
    notification: HandleValueNotification,
    indication: HandleValueIndication,
    confirmation: void,
    unknown: u8,
};

pub const ErrorResponse = struct {
    request_opcode: u8,
    handle: u16,
    error_code: ErrorCode,
};

pub const ExchangeMtuRequest = struct { client_mtu: u16 };
pub const ExchangeMtuResponse = struct { server_mtu: u16 };

pub const ReadByGroupTypeRequest = struct {
    start_handle: u16,
    end_handle: u16,
    uuid: UUID,
};

pub const ReadByGroupTypeResponse = struct {
    length: u8,
    data: []const u8,
};

pub const ReadByTypeRequest = struct {
    start_handle: u16,
    end_handle: u16,
    uuid: UUID,
};

pub const ReadByTypeResponse = struct {
    length: u8,
    data: []const u8,
};

pub const FindInformationRequest = struct {
    start_handle: u16,
    end_handle: u16,
};

pub const FindInformationResponse = struct {
    format: u8,
    data: []const u8,
};

pub const ReadRequest = struct { handle: u16 };
pub const ReadResponse = struct { value: []const u8 };
pub const ReadBlobRequest = struct { handle: u16, offset: u16 };

pub const WriteRequest = struct {
    handle: u16,
    value: []const u8,
};

pub const WriteCommand = struct {
    handle: u16,
    value: []const u8,
};

pub const HandleValueNotification = struct {
    handle: u16,
    value: []const u8,
};

pub const HandleValueIndication = struct {
    handle: u16,
    value: []const u8,
};

/// Decode an ATT PDU from raw bytes.
pub fn decodePdu(raw: []const u8) ?Pdu {
    if (raw.len < 1) return null;
    const opcode = raw[0];
    const params = raw[1..];

    return switch (opcode) {
        ERROR_RESPONSE => blk: {
            if (params.len < 4) break :blk null;
            break :blk .{ .error_response = .{
                .request_opcode = params[0],
                .handle = std.mem.readInt(u16, params[1..3], .little),
                .error_code = @enumFromInt(params[3]),
            } };
        },
        EXCHANGE_MTU_REQUEST => blk: {
            if (params.len < 2) break :blk null;
            break :blk .{ .exchange_mtu_request = .{
                .client_mtu = std.mem.readInt(u16, params[0..2], .little),
            } };
        },
        EXCHANGE_MTU_RESPONSE => blk: {
            if (params.len < 2) break :blk null;
            break :blk .{ .exchange_mtu_response = .{
                .server_mtu = std.mem.readInt(u16, params[0..2], .little),
            } };
        },
        READ_BY_GROUP_TYPE_REQUEST => blk: {
            if (params.len < 4) break :blk null;
            const uuid_len = params.len - 4;
            break :blk .{ .read_by_group_type_request = .{
                .start_handle = std.mem.readInt(u16, params[0..2], .little),
                .end_handle = std.mem.readInt(u16, params[2..4], .little),
                .uuid = UUID.readFrom(params[4..], uuid_len) orelse break :blk null,
            } };
        },
        READ_BY_GROUP_TYPE_RESPONSE => blk: {
            if (params.len < 1) break :blk null;
            break :blk .{ .read_by_group_type_response = .{
                .length = params[0],
                .data = params[1..],
            } };
        },
        READ_BY_TYPE_REQUEST => blk: {
            if (params.len < 4) break :blk null;
            const uuid_len = params.len - 4;
            break :blk .{ .read_by_type_request = .{
                .start_handle = std.mem.readInt(u16, params[0..2], .little),
                .end_handle = std.mem.readInt(u16, params[2..4], .little),
                .uuid = UUID.readFrom(params[4..], uuid_len) orelse break :blk null,
            } };
        },
        READ_BY_TYPE_RESPONSE => blk: {
            if (params.len < 1) break :blk null;
            break :blk .{ .read_by_type_response = .{
                .length = params[0],
                .data = params[1..],
            } };
        },
        FIND_INFORMATION_REQUEST => blk: {
            if (params.len < 4) break :blk null;
            break :blk .{ .find_information_request = .{
                .start_handle = std.mem.readInt(u16, params[0..2], .little),
                .end_handle = std.mem.readInt(u16, params[2..4], .little),
            } };
        },
        FIND_INFORMATION_RESPONSE => blk: {
            if (params.len < 1) break :blk null;
            break :blk .{ .find_information_response = .{
                .format = params[0],
                .data = params[1..],
            } };
        },
        READ_REQUEST => blk: {
            if (params.len < 2) break :blk null;
            break :blk .{ .read_request = .{
                .handle = std.mem.readInt(u16, params[0..2], .little),
            } };
        },
        READ_RESPONSE => .{ .read_response = .{ .value = params } },
        READ_BLOB_REQUEST => blk: {
            if (params.len < 4) break :blk null;
            break :blk .{ .read_blob_request = .{
                .handle = std.mem.readInt(u16, params[0..2], .little),
                .offset = std.mem.readInt(u16, params[2..4], .little),
            } };
        },
        WRITE_REQUEST => blk: {
            if (params.len < 2) break :blk null;
            break :blk .{ .write_request = .{
                .handle = std.mem.readInt(u16, params[0..2], .little),
                .value = params[2..],
            } };
        },
        WRITE_COMMAND => blk: {
            if (params.len < 2) break :blk null;
            break :blk .{ .write_command = .{
                .handle = std.mem.readInt(u16, params[0..2], .little),
                .value = params[2..],
            } };
        },
        WRITE_RESPONSE => .{ .write_response = {} },
        HANDLE_VALUE_NOTIFICATION => blk: {
            if (params.len < 2) break :blk null;
            break :blk .{ .notification = .{
                .handle = std.mem.readInt(u16, params[0..2], .little),
                .value = params[2..],
            } };
        },
        HANDLE_VALUE_INDICATION => blk: {
            if (params.len < 2) break :blk null;
            break :blk .{ .indication = .{
                .handle = std.mem.readInt(u16, params[0..2], .little),
                .value = params[2..],
            } };
        },
        HANDLE_VALUE_CONFIRMATION => .{ .confirmation = {} },
        else => .{ .unknown = opcode },
    };
}

pub fn encodeErrorResponse(buf: []u8, request_opcode: u8, handle: u16, code: ErrorCode) []const u8 {
    std.debug.assert(buf.len >= 5);
    buf[0] = ERROR_RESPONSE;
    buf[1] = request_opcode;
    std.mem.writeInt(u16, buf[2..4], handle, .little);
    buf[4] = @intFromEnum(code);
    return buf[0..5];
}

pub fn encodeMtuRequest(buf: []u8, mtu: u16) []const u8 {
    std.debug.assert(buf.len >= 3);
    buf[0] = EXCHANGE_MTU_REQUEST;
    std.mem.writeInt(u16, buf[1..3], mtu, .little);
    return buf[0..3];
}

pub fn encodeMtuResponse(buf: []u8, mtu: u16) []const u8 {
    std.debug.assert(buf.len >= 3);
    buf[0] = EXCHANGE_MTU_RESPONSE;
    std.mem.writeInt(u16, buf[1..3], mtu, .little);
    return buf[0..3];
}

pub fn encodeReadByGroupTypeRequest(buf: []u8, start_handle: u16, end_handle: u16, uuid: UUID) []const u8 {
    const uuid_len = uuid.byteLen();
    std.debug.assert(buf.len >= 5 + uuid_len);
    buf[0] = READ_BY_GROUP_TYPE_REQUEST;
    std.mem.writeInt(u16, buf[1..3], start_handle, .little);
    std.mem.writeInt(u16, buf[3..5], end_handle, .little);
    _ = uuid.writeTo(buf[5 .. 5 + uuid_len]);
    return buf[0 .. 5 + uuid_len];
}

pub fn encodeReadByTypeRequest(buf: []u8, start_handle: u16, end_handle: u16, uuid: UUID) []const u8 {
    const uuid_len = uuid.byteLen();
    std.debug.assert(buf.len >= 5 + uuid_len);
    buf[0] = READ_BY_TYPE_REQUEST;
    std.mem.writeInt(u16, buf[1..3], start_handle, .little);
    std.mem.writeInt(u16, buf[3..5], end_handle, .little);
    _ = uuid.writeTo(buf[5 .. 5 + uuid_len]);
    return buf[0 .. 5 + uuid_len];
}

pub fn encodeFindInformationRequest(buf: []u8, start_handle: u16, end_handle: u16) []const u8 {
    std.debug.assert(buf.len >= 5);
    buf[0] = FIND_INFORMATION_REQUEST;
    std.mem.writeInt(u16, buf[1..3], start_handle, .little);
    std.mem.writeInt(u16, buf[3..5], end_handle, .little);
    return buf[0..5];
}

pub fn encodeReadRequest(buf: []u8, handle: u16) []const u8 {
    std.debug.assert(buf.len >= 3);
    buf[0] = READ_REQUEST;
    std.mem.writeInt(u16, buf[1..3], handle, .little);
    return buf[0..3];
}

pub fn encodeReadBlobRequest(buf: []u8, handle: u16, offset: u16) []const u8 {
    std.debug.assert(buf.len >= 5);
    buf[0] = READ_BLOB_REQUEST;
    std.mem.writeInt(u16, buf[1..3], handle, .little);
    std.mem.writeInt(u16, buf[3..5], offset, .little);
    return buf[0..5];
}

pub fn encodeReadResponse(buf: []u8, value: []const u8) []const u8 {
    std.debug.assert(buf.len >= 1 + value.len);
    buf[0] = READ_RESPONSE;
    @memcpy(buf[1..][0..value.len], value);
    return buf[0 .. 1 + value.len];
}

pub fn encodeWriteRequest(buf: []u8, handle: u16, value: []const u8) []const u8 {
    std.debug.assert(buf.len >= 3 + value.len);
    buf[0] = WRITE_REQUEST;
    std.mem.writeInt(u16, buf[1..3], handle, .little);
    @memcpy(buf[3..][0..value.len], value);
    return buf[0 .. 3 + value.len];
}

pub fn encodeWriteCommand(buf: []u8, handle: u16, value: []const u8) []const u8 {
    std.debug.assert(buf.len >= 3 + value.len);
    buf[0] = WRITE_COMMAND;
    std.mem.writeInt(u16, buf[1..3], handle, .little);
    @memcpy(buf[3..][0..value.len], value);
    return buf[0 .. 3 + value.len];
}

pub fn encodeWriteResponse(buf: []u8) []const u8 {
    std.debug.assert(buf.len >= 1);
    buf[0] = WRITE_RESPONSE;
    return buf[0..1];
}

pub fn encodeNotification(buf: []u8, handle: u16, value: []const u8) []const u8 {
    std.debug.assert(buf.len >= 3 + value.len);
    buf[0] = HANDLE_VALUE_NOTIFICATION;
    std.mem.writeInt(u16, buf[1..3], handle, .little);
    @memcpy(buf[3..][0..value.len], value);
    return buf[0 .. 3 + value.len];
}

pub fn encodeIndication(buf: []u8, handle: u16, value: []const u8) []const u8 {
    std.debug.assert(buf.len >= 3 + value.len);
    buf[0] = HANDLE_VALUE_INDICATION;
    std.mem.writeInt(u16, buf[1..3], handle, .little);
    @memcpy(buf[3..][0..value.len], value);
    return buf[0 .. 3 + value.len];
}

pub fn encodeConfirmation(buf: []u8) []const u8 {
    std.debug.assert(buf.len >= 1);
    buf[0] = HANDLE_VALUE_CONFIRMATION;
    return buf[0..1];
}

test "bt/unit_tests/host/att/UUID" {
    const a = UUID.from16(0x180D);
    const b = UUID.from16(0x180D);
    const c = UUID.from16(0x2A37);

    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
    try std.testing.expectEqual(@as(usize, 2), a.byteLen());
}

test "bt/unit_tests/host/att/decode_error_response" {
    const raw = [_]u8{ ERROR_RESPONSE, READ_REQUEST, 0x01, 0x00, @intFromEnum(ErrorCode.invalid_handle) };
    const pdu = decodePdu(&raw) orelse return error.DecodeFailed;
    switch (pdu) {
        .error_response => |err_resp| {
            try std.testing.expectEqual(READ_REQUEST, err_resp.request_opcode);
            try std.testing.expectEqual(@as(u16, 0x0001), err_resp.handle);
            try std.testing.expectEqual(ErrorCode.invalid_handle, err_resp.error_code);
        },
        else => return error.WrongVariant,
    }
}

test "bt/unit_tests/host/att/encode_decode_mtu_request_roundtrip" {
    var buf: [8]u8 = undefined;
    const raw = encodeMtuRequest(&buf, 185);
    const pdu = decodePdu(raw) orelse return error.DecodeFailed;
    switch (pdu) {
        .exchange_mtu_request => |req| try std.testing.expectEqual(@as(u16, 185), req.client_mtu),
        else => return error.WrongVariant,
    }
}

test "bt/unit_tests/host/att/encode_decode_read_request_roundtrip" {
    var buf: [8]u8 = undefined;
    const raw = encodeReadRequest(&buf, 0x0025);
    const pdu = decodePdu(raw) orelse return error.DecodeFailed;
    switch (pdu) {
        .read_request => |req| try std.testing.expectEqual(@as(u16, 0x0025), req.handle),
        else => return error.WrongVariant,
    }
}

test "bt/unit_tests/host/att/encode_decode_write_request_roundtrip" {
    var buf: [16]u8 = undefined;
    const raw = encodeWriteRequest(&buf, 0x0025, "abc");
    const pdu = decodePdu(raw) orelse return error.DecodeFailed;
    switch (pdu) {
        .write_request => |req| {
            try std.testing.expectEqual(@as(u16, 0x0025), req.handle);
            try std.testing.expectEqualSlices(u8, "abc", req.value);
        },
        else => return error.WrongVariant,
    }
}

test "bt/unit_tests/host/att/encode_decode_notification_roundtrip" {
    var buf: [16]u8 = undefined;
    const raw = encodeNotification(&buf, 0x0025, "xy");
    const pdu = decodePdu(raw) orelse return error.DecodeFailed;
    switch (pdu) {
        .notification => |ntf| {
            try std.testing.expectEqual(@as(u16, 0x0025), ntf.handle);
            try std.testing.expectEqualSlices(u8, "xy", ntf.value);
        },
        else => return error.WrongVariant,
    }
}

test "bt/unit_tests/host/att/decode_returns_null_for_empty_input" {
    try std.testing.expectEqual(@as(?Pdu, null), decodePdu(&.{}));
}
