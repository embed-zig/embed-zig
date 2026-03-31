const TypeA = @import("../io/TypeA.zig");

pub const Card = struct {
    atqa: [2]u8 = .{ 0, 0 },
    uid: [15]u8 = [_]u8{0} ** 15,
    sak: [3]u8 = [_]u8{0} ** 3,
};

pub fn activate(type_a: TypeA) TypeA.Error!Card {
    var card = Card{};

    try request(type_a, &card.atqa);

    switch (card.atqa[0] & 0xC0) {
        0x00 => {
            try anticollision(type_a, 0x93, card.uid[0..5]);
            try select(type_a, 0x93, card.uid[0..5], &card.sak[0]);
        },
        0x40 => {
            try anticollision(type_a, 0x93, card.uid[0..5]);
            try select(type_a, 0x93, card.uid[0..5], &card.sak[0]);
            try anticollision(type_a, 0x95, card.uid[5..10]);
            try select(type_a, 0x95, card.uid[5..10], &card.sak[1]);
        },
        0x80 => {
            try anticollision(type_a, 0x93, card.uid[0..5]);
            try select(type_a, 0x93, card.uid[0..5], &card.sak[0]);
            try anticollision(type_a, 0x95, card.uid[5..10]);
            try select(type_a, 0x95, card.uid[5..10], &card.sak[1]);
            try anticollision(type_a, 0x97, card.uid[10..15]);
            try select(type_a, 0x97, card.uid[10..15], &card.sak[2]);
        },
        else => return error.Protocol,
    }

    return card;
}

fn request(type_a: TypeA, out_atqa: *[2]u8) TypeA.Error!void {
    var rx: [2]u8 = undefined;
    const bits = try type_a.transceive(.{
        .tx = &.{0x26},
        .tx_bits = 7,
        .timeout_ms = 1,
    }, &rx);

    if (bits != 16) return error.Protocol;
    out_atqa.* = rx;
}

fn anticollision(type_a: TypeA, cascade_code: u8, out_uid: []u8) TypeA.Error!void {
    if (out_uid.len < 5) return error.InvalidArgument;

    var rx: [5]u8 = undefined;
    const bits = try type_a.transceive(.{
        .tx = &.{ cascade_code, 0x20 },
        .tx_bits = 16,
        .timeout_ms = 1,
        .reset_collision = true,
    }, &rx);

    if (bits != 40) return error.Protocol;
    if (rx[4] != (rx[0] ^ rx[1] ^ rx[2] ^ rx[3])) return error.Protocol;
    @memcpy(out_uid[0..5], &rx);
}

fn select(type_a: TypeA, cascade_code: u8, in_uid: []const u8, out_sak: *u8) TypeA.Error!void {
    if (in_uid.len < 5) return error.InvalidArgument;

    var tx: [7]u8 = .{ cascade_code, 0x70, 0, 0, 0, 0, 0 };
    @memcpy(tx[2..], in_uid[0..5]);

    var rx: [1]u8 = undefined;
    const bits = try type_a.transceive(.{
        .tx = &tx,
        .tx_bits = tx.len * 8,
        .timeout_ms = 1,
        .tx_crc = true,
        .rx_crc = true,
    }, &rx);

    if (bits < 8) return error.Protocol;
    out_sak.* = rx[0];
}

test "drivers/unit_tests/nfc/fm175xx/type_a/activate_single_cascade_uid" {
    const std = @import("std");

    const Fake = struct {
        step: usize = 0,

        fn transceive(self: *@This(), exchange: TypeA.Exchange, rx: []u8) TypeA.Error!usize {
            defer self.step += 1;

            switch (self.step) {
                0 => {
                    try std.testing.expectEqualSlices(u8, &.{0x26}, exchange.tx);
                    try std.testing.expectEqual(@as(usize, 7), exchange.tx_bits);
                    try std.testing.expect(!exchange.tx_crc);
                    try std.testing.expect(!exchange.rx_crc);
                    try std.testing.expect(!exchange.reset_collision);
                    rx[0] = 0x04;
                    rx[1] = 0x00;
                    return 16;
                },
                1 => {
                    try std.testing.expectEqualSlices(u8, &.{ 0x93, 0x20 }, exchange.tx);
                    try std.testing.expect(exchange.reset_collision);
                    rx[0] = 0xDE;
                    rx[1] = 0xAD;
                    rx[2] = 0xBE;
                    rx[3] = 0xEF;
                    rx[4] = 0xDE ^ 0xAD ^ 0xBE ^ 0xEF;
                    return 40;
                },
                2 => {
                    try std.testing.expectEqualSlices(u8, &.{ 0x93, 0x70, 0xDE, 0xAD, 0xBE, 0xEF, 0x22 }, exchange.tx);
                    try std.testing.expect(exchange.tx_crc);
                    try std.testing.expect(exchange.rx_crc);
                    rx[0] = 0x08;
                    return 8;
                },
                else => return error.Unexpected,
            }
        }
    };

    var fake = Fake{};
    const card = try activate(TypeA.init(&fake));

    try std.testing.expectEqual(@as(u8, 0x04), card.atqa[0]);
    try std.testing.expectEqual(@as(u8, 0x00), card.atqa[1]);
    try std.testing.expectEqualSlices(u8, &.{ 0xDE, 0xAD, 0xBE, 0xEF, 0x22 }, card.uid[0..5]);
    try std.testing.expectEqual(@as(u8, 0x08), card.sak[0]);
}

test "drivers/unit_tests/nfc/fm175xx/type_a/activate_triple_cascade_uid" {
    const std = @import("std");

    const Fake = struct {
        step: usize = 0,

        fn anticollisionResponse(base: u8, rx: []u8) void {
            rx[0] = base;
            rx[1] = base + 1;
            rx[2] = base + 2;
            rx[3] = base + 3;
            rx[4] = rx[0] ^ rx[1] ^ rx[2] ^ rx[3];
        }

        fn transceive(self: *@This(), exchange: TypeA.Exchange, rx: []u8) TypeA.Error!usize {
            defer self.step += 1;

            switch (self.step) {
                0 => {
                    rx[0] = 0x80;
                    rx[1] = 0x00;
                    return 16;
                },
                1 => {
                    try std.testing.expectEqualSlices(u8, &.{ 0x93, 0x20 }, exchange.tx);
                    anticollisionResponse(0x10, rx);
                    return 40;
                },
                2 => {
                    rx[0] = 0x88;
                    return 8;
                },
                3 => {
                    try std.testing.expectEqualSlices(u8, &.{ 0x95, 0x20 }, exchange.tx);
                    anticollisionResponse(0x20, rx);
                    return 40;
                },
                4 => {
                    rx[0] = 0x88;
                    return 8;
                },
                5 => {
                    try std.testing.expectEqualSlices(u8, &.{ 0x97, 0x20 }, exchange.tx);
                    anticollisionResponse(0x30, rx);
                    return 40;
                },
                6 => {
                    rx[0] = 0x04;
                    return 8;
                },
                else => return error.Unexpected,
            }
        }
    };

    var fake = Fake{};
    const card = try activate(TypeA.init(&fake));

    try std.testing.expectEqualSlices(u8, &.{ 0x10, 0x11, 0x12, 0x13, 0x00 }, card.uid[0..5]);
    try std.testing.expectEqualSlices(u8, &.{ 0x20, 0x21, 0x22, 0x23, 0x00 }, card.uid[5..10]);
    try std.testing.expectEqualSlices(u8, &.{ 0x30, 0x31, 0x32, 0x33, 0x00 }, card.uid[10..15]);
    try std.testing.expectEqual(@as(u8, 0x88), card.sak[0]);
    try std.testing.expectEqual(@as(u8, 0x88), card.sak[1]);
    try std.testing.expectEqual(@as(u8, 0x04), card.sak[2]);
}

test "drivers/unit_tests/nfc/fm175xx/type_a/activate_double_cascade_uid" {
    const std = @import("std");

    const Fake = struct {
        step: usize = 0,

        fn transceive(self: *@This(), exchange: TypeA.Exchange, rx: []u8) TypeA.Error!usize {
            defer self.step += 1;

            switch (self.step) {
                0 => {
                    rx[0] = 0x40;
                    rx[1] = 0x00;
                    return 16;
                },
                1 => {
                    try std.testing.expectEqualSlices(u8, &.{ 0x93, 0x20 }, exchange.tx);
                    rx[0] = 0xAA;
                    rx[1] = 0xBB;
                    rx[2] = 0xCC;
                    rx[3] = 0xDD;
                    rx[4] = 0x00;
                    return 40;
                },
                2 => {
                    rx[0] = 0x88;
                    return 8;
                },
                3 => {
                    try std.testing.expectEqualSlices(u8, &.{ 0x95, 0x20 }, exchange.tx);
                    rx[0] = 0x01;
                    rx[1] = 0x02;
                    rx[2] = 0x03;
                    rx[3] = 0x00;
                    rx[4] = 0x00;
                    rx[4] = rx[0] ^ rx[1] ^ rx[2] ^ rx[3];
                    return 40;
                },
                4 => {
                    rx[0] = 0x04;
                    return 8;
                },
                else => return error.Unexpected,
            }
        }
    };

    var fake = Fake{};
    const card = try activate(TypeA.init(&fake));

    try std.testing.expectEqualSlices(u8, &.{ 0xAA, 0xBB, 0xCC, 0xDD, 0x00 }, card.uid[0..5]);
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0x02, 0x03, 0x00, 0x00 }, card.uid[5..10]);
    try std.testing.expectEqual(@as(u8, 0x88), card.sak[0]);
    try std.testing.expectEqual(@as(u8, 0x04), card.sak[1]);
}

test "drivers/unit_tests/nfc/fm175xx/type_a/rejects_invalid_bcc" {
    const std = @import("std");

    const Fake = struct {
        step: usize = 0,

        fn transceive(self: *@This(), exchange: TypeA.Exchange, rx: []u8) TypeA.Error!usize {
            defer self.step += 1;

            switch (self.step) {
                0 => {
                    rx[0] = 0x04;
                    rx[1] = 0x00;
                    return 16;
                },
                1 => {
                    try std.testing.expectEqualSlices(u8, &.{ 0x93, 0x20 }, exchange.tx);
                    rx[0] = 1;
                    rx[1] = 2;
                    rx[2] = 3;
                    rx[3] = 4;
                    rx[4] = 0xFF;
                    return 40;
                },
                else => return error.Unexpected,
            }
        }
    };

    var fake = Fake{};
    try std.testing.expectError(error.Protocol, activate(TypeA.init(&fake)));
}
