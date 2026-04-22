const embed = @import("embed");
const testing_api = @import("testing");

pub const Central = @import("unit/Central.zig");
pub const Peripheral = @import("unit/Peripheral.zig");
pub const host = struct {
    pub const Host = @import("unit/Host.zig");
    pub const Central = @import("unit/host/Central.zig");
    pub const Peripheral = @import("unit/host/Peripheral.zig");
    pub const Gap = @import("unit/host/Gap.zig");
    pub const Hci = @import("unit/host/Hci.zig");
    pub const att = @import("unit/host/att.zig");
    pub const l2cap = @import("unit/host/l2cap.zig");

    pub const gatt = struct {
        pub const client = @import("unit/host/gatt/client.zig");
        pub const server = @import("unit/host/gatt/server.zig");
    };

    pub const hci = struct {
        pub const status = @import("unit/host/hci/status.zig");
        pub const commands = @import("unit/host/hci/commands.zig");
        pub const events = @import("unit/host/hci/events.zig");
        pub const acl = @import("unit/host/hci/acl.zig");
    };

    pub const server = struct {
        pub const Receiver = @import("unit/host/server/Receiver.zig");
        pub const Server = @import("unit/host/server/Server.zig");
        pub const Sender = @import("unit/host/server/Sender.zig");
    };

    pub const xfer = struct {
        pub const Chunk = @import("unit/host/xfer/Chunk.zig");
        pub const read = @import("unit/host/xfer/read.zig");
        pub const send = @import("unit/host/xfer/send.zig");
        pub const write = @import("unit/host/xfer/write.zig");
        pub const recv = @import("unit/host/xfer/recv.zig");
    };
};

pub const Hci = @import("unit/Hci.zig");
pub const mocker = struct {
    pub const Hci = @import("unit/mocker/Hci.zig");
};

pub fn make(comptime lib: type) testing_api.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: embed.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            t.run("Central", Central.make(lib));
            t.run("Peripheral", Peripheral.make(lib));
            t.run("Host", host.Host.make(lib));
            t.run("Hci", Hci.make(lib));
            t.run("host/Central", host.Central.make(lib));
            t.run("host/Peripheral", host.Peripheral.make(lib));
            t.run("host/Gap", host.Gap.make(lib));
            t.run("host/Hci", host.Hci.make(lib));
            t.run("host/att", host.att.make(lib));
            t.run("host/l2cap", host.l2cap.make(lib));
            t.run("host/gatt/client", host.gatt.client.make(lib));
            t.run("host/gatt/server", host.gatt.server.make(lib));
            t.run("host/hci/status", host.hci.status.make(lib));
            t.run("host/hci/commands", host.hci.commands.make(lib));
            t.run("host/hci/events", host.hci.events.make(lib));
            t.run("host/hci/acl", host.hci.acl.make(lib));
            t.run("host/server/Receiver", host.server.Receiver.make(lib));
            t.run("host/server/Server", host.server.Server.make(lib));
            t.run("host/server/Sender", host.server.Sender.make(lib));
            t.run("host/xfer/Chunk", host.xfer.Chunk.make(lib));
            t.run("host/xfer/read", host.xfer.read.make(lib));
            t.run("host/xfer/send", host.xfer.send.make(lib));
            t.run("host/xfer/write", host.xfer.write.make(lib));
            t.run("host/xfer/recv", host.xfer.recv.make(lib));
            t.run("mocker/Hci", mocker.Hci.make(lib));
            return t.wait();
        }

        pub fn deinit(self: *@This(), allocator: embed.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}
