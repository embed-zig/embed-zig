const builtin = @import("builtin");
const net_mod = @import("net");
const runtime = net_mod.runtime;

pub const impl = switch (builtin.target.os.tag) {
    .macos, .ios, .watchos, .tvos => @import("net/darwin.zig"),
    .linux => @import("net/linux.zig"),
    .windows => @import("net/windows.zig"),
    else => @compileError("embed_std.net is not supported on this OS yet"),
};

pub const api = runtime.make(impl);

pub const Domain = runtime.Domain;
pub const ShutdownHow = runtime.ShutdownHow;
pub const PollEvents = runtime.PollEvents;
pub const SignalEvent = runtime.SignalEvent;

pub const CreateError = runtime.CreateError;
pub const SocketError = runtime.SocketError;
pub const SetSockOptError = runtime.SetSockOptError;
pub const PollError = runtime.PollError;

pub const SocketLevelOption = runtime.SocketLevelOption;
pub const TcpLevelOption = runtime.TcpLevelOption;
pub const TcpOption = runtime.TcpOption;
pub const UdpOption = runtime.UdpOption;

pub const Tcp = api.Tcp;
pub const Udp = api.Udp;

pub fn tcp(domain: Domain) CreateError!Tcp {
    return api.tcp(domain);
}

pub fn udp(domain: Domain) CreateError!Udp {
    return api.udp(domain);
}
