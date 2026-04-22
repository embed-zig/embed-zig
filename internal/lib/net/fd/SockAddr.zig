const Addr = @import("../netip/Addr.zig");
const AddrPort = @import("../netip/AddrPort.zig");

pub fn SockAddr(comptime lib: type) type {
    const mem = lib.mem;
    const posix = lib.posix;

    return struct {
        pub const EncodeError = error{
            InvalidAddress,
            InvalidScopeId,
        };

        pub const Encoded = struct {
            storage: posix.sockaddr.storage,
            len: posix.socklen_t,
            family: u32,
        };

        pub fn family(addr: Addr) EncodeError!u32 {
            if (addr.is4()) return posix.AF.INET;
            if (addr.is6()) return posix.AF.INET6;
            return error.InvalidAddress;
        }

        pub fn encode(addr_port: AddrPort) EncodeError!Encoded {
            var storage: posix.sockaddr.storage = undefined;
            zeroStorage(&storage);

            const ip = addr_port.addr();
            if (ip.is4()) {
                const sa: *posix.sockaddr.in = @ptrCast(@alignCast(&storage));
                sa.* = .{
                    .port = mem.nativeToBig(u16, addr_port.port()),
                    .addr = @as(*align(1) const u32, @ptrCast(&ip.as4().?)).*,
                };
                return .{
                    .storage = storage,
                    .len = @sizeOf(posix.sockaddr.in),
                    .family = posix.AF.INET,
                };
            }

            if (ip.is6()) {
                const sa: *posix.sockaddr.in6 = @ptrCast(@alignCast(&storage));
                sa.* = .{
                    .port = mem.nativeToBig(u16, addr_port.port()),
                    .flowinfo = 0,
                    .addr = ip.as16().?,
                    .scope_id = try parseScopeId(ip),
                };
                return .{
                    .storage = storage,
                    .len = @sizeOf(posix.sockaddr.in6),
                    .family = posix.AF.INET6,
                };
            }

            return error.InvalidAddress;
        }

        fn zeroStorage(storage: *posix.sockaddr.storage) void {
            const bytes: *[@sizeOf(posix.sockaddr.storage)]u8 = @ptrCast(storage);
            @memset(bytes, 0);
        }

        fn parseScopeId(addr: Addr) EncodeError!u32 {
            const zone = addr.zone[0..addr.zone_len];
            if (zone.len == 0) return 0;

            var scope_id: u32 = 0;
            for (zone) |c| {
                if (c < '0' or c > '9') return error.InvalidScopeId;
                scope_id = mulAddU32(scope_id, 10, c - '0') catch return error.InvalidScopeId;
            }
            return scope_id;
        }

        fn mulAddU32(base: u32, factor: u32, addend: u32) error{Overflow}!u32 {
            const mul = @mulWithOverflow(base, factor);
            if (mul[1] != 0) return error.Overflow;
            const sum = @addWithOverflow(mul[0], addend);
            if (sum[1] != 0) return error.Overflow;
            return sum[0];
        }
    };
}
