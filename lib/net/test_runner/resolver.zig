//! Resolver test runner — DNS wire format + integration tests.
//!
//! Unit tests (buildQuery, parseResponse) use hand-crafted packets.
//! Integration test performs a real DNS lookup against public servers.
//!
//! Usage:
//!   const runner = @import("net/test_runner/resolver.zig");
//!   test { runner.run(std); }

const resolver_mod = @import("../Resolver.zig");

pub fn run(comptime lib: type) void {
    const R = resolver_mod.Resolver(lib);
    const Addr = lib.net.Address;
    const testing = lib.testing;

    _ = struct {
        test "buildQuery round-trip" {
            var buf: [512]u8 = undefined;
            const len = try R.buildQuery(&buf, "example.com", R.QTYPE_A, 0x1234);

            try testing.expectEqual(@as(u16, 0x1234), R.readU16(buf[0..2]));
            try testing.expect(len > 12);

            try testing.expectEqual(@as(u8, 7), buf[12]);
            try testing.expectEqualStrings("example", buf[13..20]);
            try testing.expectEqual(@as(u8, 3), buf[20]);
            try testing.expectEqualStrings("com", buf[21..24]);
            try testing.expectEqual(@as(u8, 0), buf[24]);
        }

        test "parseResponse A record" {
            var pkt: [512]u8 = @splat(0);
            var pos: usize = 0;

            R.writeU16(&pkt, &pos, 0xABCD);
            R.writeU16(&pkt, &pos, 0x8180);
            R.writeU16(&pkt, &pos, 1);
            R.writeU16(&pkt, &pos, 1);
            R.writeU16(&pkt, &pos, 0);
            R.writeU16(&pkt, &pos, 0);

            pkt[pos] = 7;
            pos += 1;
            @memcpy(pkt[pos..][0..7], "example");
            pos += 7;
            pkt[pos] = 3;
            pos += 1;
            @memcpy(pkt[pos..][0..3], "com");
            pos += 3;
            pkt[pos] = 0;
            pos += 1;
            R.writeU16(&pkt, &pos, R.QTYPE_A);
            R.writeU16(&pkt, &pos, R.QCLASS_IN);

            pkt[pos] = 0xC0;
            pkt[pos + 1] = 0x0C;
            pos += 2;
            R.writeU16(&pkt, &pos, R.QTYPE_A);
            R.writeU16(&pkt, &pos, R.QCLASS_IN);
            R.writeU16(&pkt, &pos, 0);
            R.writeU16(&pkt, &pos, 300);
            R.writeU16(&pkt, &pos, 4);
            pkt[pos] = 93;
            pkt[pos + 1] = 184;
            pkt[pos + 2] = 216;
            pkt[pos + 3] = 34;
            pos += 4;

            var addrs: [4]Addr = undefined;
            const count = try R.parseResponse(pkt[0..pos], R.QTYPE_A, &addrs);
            try testing.expectEqual(@as(usize, 1), count);

            const ip: [4]u8 = @bitCast(addrs[0].in.sa.addr);
            try testing.expectEqual([4]u8{ 93, 184, 216, 34 }, ip);
        }

        test "parseResponse AAAA record" {
            var pkt: [512]u8 = @splat(0);
            var pos: usize = 0;

            R.writeU16(&pkt, &pos, 0x5678);
            R.writeU16(&pkt, &pos, 0x8180);
            R.writeU16(&pkt, &pos, 1);
            R.writeU16(&pkt, &pos, 1);
            R.writeU16(&pkt, &pos, 0);
            R.writeU16(&pkt, &pos, 0);

            pkt[pos] = 4;
            pos += 1;
            @memcpy(pkt[pos..][0..4], "test");
            pos += 4;
            pkt[pos] = 7;
            pos += 1;
            @memcpy(pkt[pos..][0..7], "example");
            pos += 7;
            pkt[pos] = 0;
            pos += 1;
            R.writeU16(&pkt, &pos, R.QTYPE_AAAA);
            R.writeU16(&pkt, &pos, R.QCLASS_IN);

            pkt[pos] = 0xC0;
            pkt[pos + 1] = 0x0C;
            pos += 2;
            R.writeU16(&pkt, &pos, R.QTYPE_AAAA);
            R.writeU16(&pkt, &pos, R.QCLASS_IN);
            R.writeU16(&pkt, &pos, 0);
            R.writeU16(&pkt, &pos, 600);
            R.writeU16(&pkt, &pos, 16);

            const ipv6_bytes = [16]u8{ 0x26, 0x06, 0x28, 0x00, 0x02, 0x20, 0x00, 0x01, 0x02, 0x48, 0x18, 0x93, 0x25, 0xc8, 0x19, 0x46 };
            @memcpy(pkt[pos..][0..16], &ipv6_bytes);
            pos += 16;

            var addrs: [4]Addr = undefined;
            const count = try R.parseResponse(pkt[0..pos], R.QTYPE_AAAA, &addrs);
            try testing.expectEqual(@as(usize, 1), count);
            try testing.expectEqual(ipv6_bytes, addrs[0].in6.sa.addr);
        }

        test "options defaults" {
            const r = R.init(.{});
            try testing.expectEqual(@as(u32, 5000), r.options.timeout_ms);
            try testing.expectEqual(@as(u32, 2), r.options.attempts);
            try testing.expectEqual(R.QueryMode.ipv4_and_ipv6, r.options.mode);
            try testing.expectEqual(@as(usize, 2), r.options.servers.len);
        }

        test "ProtocolSet" {
            const ps = R.ProtocolSet.initMany(&.{ .udp, .tcp });
            try testing.expect(ps.contains(.udp));
            try testing.expect(ps.contains(.tcp));
            try testing.expect(!ps.contains(.tls));

            const tls_only = R.ProtocolSet.initOne(.tls);
            try testing.expect(tls_only.contains(.tls));
            try testing.expect(!tls_only.contains(.udp));
        }

        test "Server per-protocol config" {
            const servers = [_]R.Server{
                .{ .addr = Addr.initIp4(.{ 8, 8, 8, 8 }, 53) },
                .{ .addr = Addr.initIp4(.{ 1, 1, 1, 1 }, 853), .protocols = R.ProtocolSet.initOne(.tls) },
            };
            try testing.expect(servers[0].protocols.contains(.udp));
            try testing.expect(servers[0].protocols.contains(.tcp));
            try testing.expect(!servers[1].protocols.contains(.udp));
            try testing.expect(servers[1].protocols.contains(.tls));
        }

        test "lookupHost real DNS" {
            var resolver = R.init(.{
                .servers = &.{
                    .{ .addr = Addr.initIp4(.{ 8, 8, 8, 8 }, 53) },
                },
                .mode = .ipv4_only,
                .timeout_ms = 3000,
                .attempts = 2,
            });
            var addrs: [8]Addr = undefined;
            const count = resolver.lookupHost("one.one.one.one", &addrs) catch |err| {
                lib.debug.print("DNS lookup skipped (no network?): {}\n", .{err});
                return;
            };
            try testing.expect(count > 0);
            const ip: [4]u8 = @bitCast(addrs[0].in.sa.addr);
            try testing.expect(ip[0] == 1);
        }
    };
}

test "std_compat" {
    const std = @import("std");
    run(std);
}
