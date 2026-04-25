const control = @import("control.zig");

pub const Frame = struct {
    dlci: u8,
    cr: bool,
    pf: bool = false,
    frame_type: control.FrameType,
    info: []const u8 = "",
};

pub const Address = struct {
    dlci: u8,
    cr: bool,
};

pub const EncodeError = error{
    BufferTooSmall,
    InvalidDlci,
    FrameTooLong,
};

pub const DecodeError = error{
    InvalidFlag,
    InvalidAddress,
    InvalidControl,
    InvalidLength,
    InvalidFcs,
    Truncated,
};

pub fn encodedLen(info_len: usize) EncodeError!usize {
    if (info_len > max_info_len) return error.FrameTooLong;
    return 1 + 1 + 1 + lengthFieldLen(info_len) + info_len + 1 + 1;
}

pub fn encode(out: []u8, frame: Frame) EncodeError![]const u8 {
    if (!control.isValidDlci(frame.dlci)) return error.InvalidDlci;

    const total_len = try encodedLen(frame.info.len);
    if (out.len < total_len) return error.BufferTooSmall;

    out[0] = control.flag;
    out[1] = encodeAddress(.{
        .dlci = frame.dlci,
        .cr = frame.cr,
    });
    out[2] = encodeControl(frame.frame_type, frame.pf);

    const header_end: usize = if (frame.info.len > 127) blk: {
        out[3] = @as(u8, @truncate(frame.info.len << 1));
        out[4] = @as(u8, @truncate(frame.info.len >> 7));
        break :blk 5;
    } else blk: {
        out[3] = @as(u8, @truncate((frame.info.len << 1) | 0x01));
        break :blk 4;
    };

    @memcpy(out[header_end .. header_end + frame.info.len], frame.info);

    const fcs_index = header_end + frame.info.len;
    out[fcs_index] = computeFcs(frame, out[1..header_end]);
    out[fcs_index + 1] = control.flag;
    return out[0 .. fcs_index + 2];
}

pub fn decode(encoded: []const u8) DecodeError!Frame {
    if (encoded.len < 6) return error.Truncated;
    if (encoded[0] != control.flag or encoded[encoded.len - 1] != control.flag) {
        return error.InvalidFlag;
    }

    const address = try decodeAddress(encoded[1]);
    const control_byte = encoded[2];
    const frame_type = try decodeControl(control_byte);
    const pf = (control_byte & control.pf_mask) != 0;

    var index: usize = 3;
    const first_len = encoded[index];
    index += 1;

    var info_len: usize = first_len >> 1;
    if ((first_len & 0x01) == 0) {
        if (encoded.len < 7) return error.Truncated;
        const second_len = encoded[index];
        index += 1;
        info_len |= (@as(usize, second_len) << 7);
    }

    if (info_len > max_info_len) return error.InvalidLength;
    if (encoded.len != index + info_len + 2) return error.InvalidLength;

    const info = encoded[index .. index + info_len];
    const expected_fcs = computeFcs(.{
        .dlci = address.dlci,
        .cr = address.cr,
        .pf = pf,
        .frame_type = frame_type,
        .info = info,
    }, encoded[1..index]);
    if (encoded[index + info_len] != expected_fcs) return error.InvalidFcs;

    return .{
        .dlci = address.dlci,
        .cr = address.cr,
        .pf = pf,
        .frame_type = frame_type,
        .info = info,
    };
}

pub fn encodeAddress(address: Address) u8 {
    return 0x01 | (if (address.cr) @as(u8, 0x02) else 0) | (address.dlci << 2);
}

pub fn decodeAddress(byte: u8) DecodeError!Address {
    if ((byte & 0x01) == 0) return error.InvalidAddress;
    return .{
        .dlci = (byte >> 2) & 0x3F,
        .cr = (byte & 0x02) != 0,
    };
}

pub fn encodeControl(frame_type: control.FrameType, pf: bool) u8 {
    return @intFromEnum(frame_type) | (if (pf) control.pf_mask else 0);
}

pub fn decodeControl(byte: u8) DecodeError!control.FrameType {
    return switch (byte & ~control.pf_mask) {
        @intFromEnum(control.FrameType.dm) => .dm,
        @intFromEnum(control.FrameType.sabm) => .sabm,
        @intFromEnum(control.FrameType.disc) => .disc,
        @intFromEnum(control.FrameType.ua) => .ua,
        @intFromEnum(control.FrameType.uih) => .uih,
        else => error.InvalidControl,
    };
}

fn lengthFieldLen(info_len: usize) usize {
    return if (info_len > 127) 2 else 1;
}

fn computeFcs(frame: Frame, header: []const u8) u8 {
    var fcs: u8 = 0xFF;
    fcs = crc8_rohc(fcs, header);
    if (frame.frame_type == .uih) return 0xFF - fcs;
    return 0xFF - crc8_rohc(fcs, frame.info);
}

fn crc8_rohc(initial: u8, buf: []const u8) u8 {
    var crc = initial;
    for (buf) |byte| {
        crc ^= byte;
        var bit: u8 = 0;
        while (bit < 8) : (bit += 1) {
            if ((crc & 0x80) != 0) {
                crc = (crc << 1) ^ 0x07;
            } else {
                crc <<= 1;
            }
        }
    }
    return crc;
}

const max_info_len = 0x7FFF;

pub fn TestRunner(comptime lib: type) @import("testing").TestRunner {
    const testing_api = @import("testing");

    const TestCase = struct {
        fn encodesAndDecodesUih() !void {
            var storage: [64]u8 = undefined;
            const encoded = try encode(&storage, .{
                .dlci = 5,
                .cr = true,
                .frame_type = .uih,
                .info = "abc",
            });
            try lib.testing.expectEqual(@as(u8, control.flag), encoded[0]);
            try lib.testing.expectEqual(@as(u8, control.flag), encoded[encoded.len - 1]);

            const decoded = try decode(encoded);
            try lib.testing.expectEqual(@as(u8, 5), decoded.dlci);
            try lib.testing.expect(decoded.cr);
            try lib.testing.expectEqual(control.FrameType.uih, decoded.frame_type);
            try lib.testing.expectEqualStrings("abc", decoded.info);
        }

        fn encodesTwoOctetLength() !void {
            var payload: [130]u8 = undefined;
            @memset(&payload, 'x');

            var storage: [256]u8 = undefined;
            const encoded = try encode(&storage, .{
                .dlci = 7,
                .cr = true,
                .frame_type = .uih,
                .info = &payload,
            });
            try lib.testing.expectEqual(@as(u8, 0), encoded[3] & 0x01);

            const decoded = try decode(encoded);
            try lib.testing.expectEqual(@as(usize, payload.len), decoded.info.len);
            try lib.testing.expectEqual(@as(u8, 'x'), decoded.info[0]);
        }

        fn rejectsInvalidDlci() !void {
            var storage: [16]u8 = undefined;
            try lib.testing.expectError(error.InvalidDlci, encode(&storage, .{
                .dlci = 64,
                .cr = true,
                .frame_type = .uih,
            }));
        }

        fn rejectsBadFcs() !void {
            var storage: [32]u8 = undefined;
            const encoded = try encode(&storage, .{
                .dlci = 2,
                .cr = false,
                .frame_type = .sabm,
            });
            storage[encoded.len - 2] ^= 0x01;
            try lib.testing.expectError(error.InvalidFcs, decode(encoded));
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

            t.run("encodesAndDecodesUih", testing_api.TestRunner.fromFn(lib, 256 * 1024, struct {
                fn run(_: *testing_api.T, _: lib.mem.Allocator) !void {
                    try TestCase.encodesAndDecodesUih();
                }
            }.run));
            t.run("encodesTwoOctetLength", testing_api.TestRunner.fromFn(lib, 256 * 1024, struct {
                fn run(_: *testing_api.T, _: lib.mem.Allocator) !void {
                    try TestCase.encodesTwoOctetLength();
                }
            }.run));
            t.run("rejectsInvalidDlci", testing_api.TestRunner.fromFn(lib, 256 * 1024, struct {
                fn run(_: *testing_api.T, _: lib.mem.Allocator) !void {
                    try TestCase.rejectsInvalidDlci();
                }
            }.run));
            t.run("rejectsBadFcs", testing_api.TestRunner.fromFn(lib, 256 * 1024, struct {
                fn run(_: *testing_api.T, _: lib.mem.Allocator) !void {
                    try TestCase.rejectsBadFcs();
                }
            }.run));
            return t.wait();
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

