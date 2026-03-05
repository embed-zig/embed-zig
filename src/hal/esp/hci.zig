const esp = @import("esp");
const hal_hci = @import("hal").hci;

const VHci = esp.bt.VHci;
const Queue = esp.freertos.queue.Queue;

const max_packet_size = 512;
const queue_depth = 8;

const PacketEntry = extern struct {
    len: u16 = 0,
    data: [max_packet_size]u8 = undefined,
};

const RxQueue = Queue(PacketEntry);

/// Callback routing pointer — the only global state.
/// Required because VHCI callbacks are bare C function pointers
/// without a user-context parameter.
var active_driver: ?*Driver = null;

fn onReadable(data: [*]u8, len: u16) callconv(.c) c_int {
    const drv = active_driver orelse return -1;
    if (len > max_packet_size) return -1;

    var entry: PacketEntry = .{ .len = len };
    @memcpy(entry.data[0..len], data[0..len]);
    drv.rx_queue.send(&entry, 0) catch return -1;
    return 0;
}

fn onWritable() callconv(.c) void {}

const vhci_callbacks = VHci.HciCallbacks{
    .on_writable = &onWritable,
    .on_readable = &onReadable,
};

pub const Driver = struct {
    rx_queue: RxQueue = .{ .handle = null },
    registered: bool = false,

    pub fn read(self: *Driver, buf: []u8) hal_hci.Error!usize {
        self.ensureRegistered();
        const entry = self.rx_queue.receive(0) catch return error.WouldBlock;
        const n = @min(entry.len, @as(u16, @intCast(buf.len)));
        @memcpy(buf[0..n], entry.data[0..n]);
        return n;
    }

    pub fn write(self: *Driver, buf: []const u8) hal_hci.Error!usize {
        self.ensureRegistered();
        if (buf.len == 0 or buf.len > 0xFFFF) return error.HciError;
        return switch (VHci.tryWrite(buf.ptr, @intCast(buf.len))) {
            .ok => buf.len,
            .would_block => error.WouldBlock,
            .invalid_length => error.HciError,
        };
    }

    pub fn poll(self: *Driver, flags: hal_hci.PollFlags, _: i32) hal_hci.PollFlags {
        self.ensureRegistered();
        return .{
            .readable = flags.readable and self.rx_queue.waiting() > 0,
            .writable = flags.writable and VHci.canWrite(),
        };
    }

    fn ensureRegistered(self: *Driver) void {
        if (!self.registered) {
            self.rx_queue = RxQueue.init(queue_depth) catch return;
            active_driver = self;
            VHci.registerCallbacks(&vhci_callbacks) catch {};
            self.registered = true;
        }
    }
};
