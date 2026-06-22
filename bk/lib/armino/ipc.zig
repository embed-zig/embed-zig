const std = @import("std");

const BK_OK = 0;
const IPC_ROUTE_CPU0_CPU1 = 0;
const MIPC_CHAN_SEND_FLAG_SYNC = 1 << 0;

const RawHandle = ?*anyopaque;
const RawRxCallback = ?*const fn ([*c]u8, u32, ?*anyopaque, ?*anyopaque) callconv(.c) u32;
const RawTxCallback = ?*const fn (?*anyopaque) callconv(.c) u32;

const RawChannelConfig = extern struct {
    ipc: *RawHandle,
    route: c_int,
    name: [*:0]const u8,
    rx_cb: RawRxCallback,
    tx_cb: RawTxCallback,
    param: ?*anyopaque,
};

extern fn bk_ipc_send(ipc: *RawHandle, data: ?*anyopaque, size: u32, flags: u32, result: *u32) c_int;

pub const Route = enum(c_int) {
    cpu0_cpu1 = IPC_ROUTE_CPU0_CPU1,
};

pub const SendOptions = struct {
    sync: bool = false,
};

pub const SendError = error{
    SendFailed,
    MessageTooLong,
};

pub const ReceiveFn = *const fn ([]const u8) void;

pub const Options = struct {
    name: [:0]const u8,
    route: Route = .cpu0_cpu1,
    receive: ?ReceiveFn = null,
};

pub fn Channel(comptime options: Options) type {
    return struct {
        var handle: RawHandle = null;

        const registration = RawChannelConfig{
            .ipc = &handle,
            .route = @intFromEnum(options.route),
            .name = options.name.ptr,
            .rx_cb = if (options.receive == null) null else rxThunk,
            .tx_cb = null,
            .param = null,
        };

        comptime {
            @export(&handle, .{ .name = options.name });
            @export(&registration, .{
                .name = options.name ++ "section",
                .section = ".ipc_chan_reg",
            });
        }

        pub fn send(bytes: []const u8, send_options: SendOptions) SendError!u32 {
            if (bytes.len > std.math.maxInt(u32)) return error.MessageTooLong;
            var result: u32 = 0;
            const flags: u32 = if (send_options.sync) MIPC_CHAN_SEND_FLAG_SYNC else 0;
            const rc = bk_ipc_send(
                &handle,
                @ptrCast(@constCast(bytes.ptr)),
                @intCast(bytes.len),
                flags,
                &result,
            );
            if (rc != BK_OK) return error.SendFailed;
            return result;
        }

        pub fn sendZ(text: [:0]const u8, send_options: SendOptions) SendError!u32 {
            return send(text[0 .. text.len + 1], send_options);
        }

        fn rxThunk(data: [*c]u8, size: u32, param: ?*anyopaque, ipc_obj: ?*anyopaque) callconv(.c) u32 {
            _ = param;
            _ = ipc_obj;
            if (data == null or size == 0) return 1;
            options.receive.?(data[0..size]);
            return BK_OK;
        }
    };
}
