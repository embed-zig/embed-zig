//! Shared helpers for fd `Packet` integration cases (each case file holds the full test).

const fd_mod = @import("../../../fd.zig");
const netip = @import("../../../netip.zig");
const sockaddr_mod = @import("../../../fd/SockAddr.zig");
const tcp_test_utils = @import("../tcp/test_utils.zig");

pub const skipIfConnectDidNotPend = tcp_test_utils.skipIfConnectDidNotPend;

pub fn Harness(comptime lib: type) type {
    const Packet = fd_mod.Packet(lib);
    const AddrPort = netip.AddrPort;
    const Addr = netip.Addr;
    const SockAddr = sockaddr_mod.SockAddr(lib);
    const posix = lib.posix;

    return struct {
        pub fn bindLoopback(addr: AddrPort) !Packet {
            const encoded = try SockAddr.encode(addr);
            var packet = try Packet.initSocket(encoded.family);
            errdefer packet.deinit();
            try posix.bind(packet.fd, @ptrCast(&encoded.storage), encoded.len);
            return packet;
        }

        pub fn localAddr(packet: *const Packet) !AddrPort {
            var bound: posix.sockaddr.storage = undefined;
            var bound_len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
            try posix.getsockname(packet.fd, @ptrCast(&bound), &bound_len);
            return switch (@as(*const posix.sockaddr, @ptrCast(&bound)).family) {
                posix.AF.INET => blk: {
                    const in: *const posix.sockaddr.in = @ptrCast(@alignCast(&bound));
                    const addr_bytes: [4]u8 = @bitCast(in.addr);
                    break :blk AddrPort.from4(addr_bytes, lib.mem.bigToNative(u16, in.port));
                },
                posix.AF.INET6 => blk: {
                    const in6: *const posix.sockaddr.in6 = @ptrCast(@alignCast(&bound));
                    var ip = Addr.from16(in6.addr);
                    if (in6.scope_id != 0) {
                        var scope_buf: [10]u8 = undefined;
                        const scope = try lib.fmt.bufPrint(&scope_buf, "{d}", .{in6.scope_id});
                        ip.zone_len = @intCast(scope.len);
                        @memcpy(ip.zone[0..scope.len], scope);
                    }
                    break :blk AddrPort.init(ip, lib.mem.bigToNative(u16, in6.port));
                },
                else => unreachable,
            };
        }

        pub fn expectFromAddrPort(result: Packet.ReadFromResult, expected_port: u16) !void {
            const sa: *const posix.sockaddr = @ptrCast(&result.addr);
            try lib.testing.expectEqual(posix.AF.INET, sa.family);
            const in: *const posix.sockaddr.in = @ptrCast(@alignCast(&result.addr));
            try lib.testing.expectEqual(expected_port, lib.mem.bigToNative(u16, in.port));
        }

        pub fn expectFromAddrPort6(result: Packet.ReadFromResult, expected_port: u16) !void {
            const sa: *const posix.sockaddr = @ptrCast(&result.addr);
            try lib.testing.expectEqual(posix.AF.INET6, sa.family);
            const in6: *const posix.sockaddr.in6 = @ptrCast(@alignCast(&result.addr));
            try lib.testing.expectEqual(expected_port, lib.mem.bigToNative(u16, in6.port));
        }

        pub fn makeIndexedMessage(buf: []u8, prefix: u8, index: usize) usize {
            buf[0] = prefix;
            var tmp = index;
            var digits: [10]u8 = undefined;
            var n: usize = 0;
            while (true) {
                digits[n] = @as(u8, @intCast(tmp % 10)) + '0';
                n += 1;
                tmp /= 10;
                if (tmp == 0) break;
            }
            var out: usize = 1;
            var i = n;
            while (i > 0) {
                i -= 1;
                buf[out] = digits[i];
                out += 1;
            }
            return out;
        }
    };
}
