const time_mod = @import("time");
const NetConn = @import("../Conn.zig");
const Session = @import("Session.zig");

pub fn make(comptime std: type, comptime time: type) type {
    const Allocator = std.mem.Allocator;
    const SessionType = Session.make(std, time);

    return struct {
        allocator: Allocator,
        session: *SessionType,
        channel: *SessionType.ChannelState,
        closed: bool = false,

        const Self = @This();

        pub fn init(allocator: Allocator, session: *SessionType, channel: *SessionType.ChannelState) Allocator.Error!NetConn {
            session.retainChannel(channel);
            errdefer session.releaseChannel(channel);

            const self = try allocator.create(Self);
            self.* = .{
                .allocator = allocator,
                .session = session,
                .channel = channel,
            };
            return NetConn.init(self);
        }

        pub fn read(self: *Self, buf: []u8) NetConn.ReadError!usize {
            if (self.closed) return error.EndOfStream;
            return self.session.readChannel(self.channel, buf);
        }

        pub fn write(self: *Self, buf: []const u8) NetConn.WriteError!usize {
            if (self.closed) return error.BrokenPipe;
            return self.session.writeChannel(self.channel, buf);
        }

        pub fn close(self: *Self) void {
            if (self.closed) return;
            self.closed = true;
            self.session.closeChannel(self.channel);
        }

        pub fn deinit(self: *Self) void {
            self.close();
            self.session.releaseChannel(self.channel);
            self.allocator.destroy(self);
        }

        pub fn setReadDeadline(self: *Self, deadline: ?time_mod.instant.Time) void {
            self.session.setChannelReadDeadline(self.channel, deadline);
        }

        pub fn setWriteDeadline(self: *Self, deadline: ?time_mod.instant.Time) void {
            self.session.setChannelWriteDeadline(self.channel, deadline);
        }
    };
}
