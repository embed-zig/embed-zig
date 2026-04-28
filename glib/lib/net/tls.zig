//! tls — TLS module namespace.
//!
//! Phase 1 exposes the pure protocol building blocks used by the future
//! client/server handshake and record-layer implementation.

const common = @import("tls/common.zig");
const alert = @import("tls/alert.zig");
const extensions = @import("tls/extensions.zig");
const kdf = @import("tls/kdf.zig");
const record = @import("tls/record.zig");
const client_handshake = @import("tls/client_handshake.zig");
const server_handshake = @import("tls/server_handshake.zig");
const conn_impl = @import("tls/Conn.zig");
const server_conn_impl = @import("tls/ServerConn.zig");
const listener_impl = @import("tls/Listener.zig");
const dialer_impl = @import("tls/Dialer.zig");
const netip = @import("netip.zig");
const NetConn = @import("Conn.zig");
const NetListener = @import("Listener.zig");
const tcp_listener = @import("TcpListener.zig");
const Context = @import("context").Context;

pub fn make(comptime std: type, comptime net: type) type {
    const C = common.make(std);
    const A = alert.make(std);
    const E = extensions.make(std);
    const K = kdf.make(std);
    const R = record.make(std);
    const CH = client_handshake.make(std, net.time);
    const SH = server_handshake.make(std);
    const TC = conn_impl.Conn(std, net);
    const SC = server_conn_impl.ServerConn(std, net);
    const TL = listener_impl.Listener(std, net);
    const TlsDialer = dialer_impl.Dialer(std, net);
    const NTL = tcp_listener.TcpListener(std, net);
    const NetDialer = @import("Dialer.zig").Dialer(std, net);

    return struct {
        pub const ProtocolVersion = C.ProtocolVersion;
        pub const ContentType = C.ContentType;
        pub const HandshakeType = C.HandshakeType;
        pub const CipherSuite = C.CipherSuite;
        pub const Tls13Hash = C.Tls13Hash;
        pub const Tls13CipherProfile = C.Tls13CipherProfile;
        pub const DEFAULT_TLS12_CIPHER_SUITES = C.DEFAULT_TLS12_CIPHER_SUITES;
        pub const DEFAULT_TLS13_CIPHER_SUITES = C.DEFAULT_TLS13_CIPHER_SUITES;
        pub const isSupportedTls12CipherSuite = C.isSupportedTls12CipherSuite;
        pub const validateTls12CipherSuites = C.validateTls12CipherSuites;
        pub const validateTls13CipherSuites = C.validateTls13CipherSuites;
        pub const NamedGroup = C.NamedGroup;
        pub const SignatureScheme = C.SignatureScheme;
        pub const ExtensionType = C.ExtensionType;
        pub const AlertLevel = C.AlertLevel;
        pub const AlertDescription = C.AlertDescription;
        pub const Alert = C.Alert;
        pub const ChangeCipherSpecType = C.ChangeCipherSpecType;
        pub const CompressionMethod = C.CompressionMethod;
        pub const PskKeyExchangeMode = C.PskKeyExchangeMode;
        pub const MAX_PLAINTEXT_LEN = C.MAX_PLAINTEXT_LEN;
        pub const MAX_CIPHERTEXT_LEN = C.MAX_CIPHERTEXT_LEN;
        pub const MAX_CIPHERTEXT_LEN_TLS12 = C.MAX_CIPHERTEXT_LEN_TLS12;
        pub const RECORD_HEADER_LEN = C.RECORD_HEADER_LEN;
        pub const MAX_HANDSHAKE_LEN = C.MAX_HANDSHAKE_LEN;
        pub const RecordHeader = C.RecordHeader;
        pub const HandshakeHeader = C.HandshakeHeader;

        pub const AlertError = A.AlertError;
        pub const alertToError = A.alertToError;
        pub const errorToAlert = A.errorToAlert;
        pub const parseAlert = A.parseAlert;
        pub const serializeAlert = A.serializeAlert;

        pub const ExtensionError = E.ExtensionError;
        pub const KeyShareEntry = E.KeyShareEntry;
        pub const Extension = E.Extension;
        pub const ExtensionBuilder = E.ExtensionBuilder;
        pub const parseExtensions = E.parseExtensions;
        pub const findExtension = E.findExtension;
        pub const parseServerName = E.parseServerName;
        pub const parseSupportedVersion = E.parseSupportedVersion;
        pub const parseKeyShareServer = E.parseKeyShareServer;

        pub const Kdf = K;
        pub const TranscriptHash = K.TranscriptHash;
        pub const TranscriptPair = K.TranscriptPair;
        pub const MAX_TLS13_SECRET_LEN = K.MAX_TLS13_SECRET_LEN;
        pub const MAX_TLS13_DIGEST_LEN = K.MAX_TLS13_DIGEST_LEN;
        pub const hkdfExpandLabel = K.hkdfExpandLabel;
        pub const hkdfExpandLabelInto = K.hkdfExpandLabelInto;
        pub const hkdfExpandLabelSha256 = K.hkdfExpandLabelSha256;
        pub const hkdfExpandLabelSha384 = K.hkdfExpandLabelSha384;
        pub const deriveSecret = K.deriveSecret;
        pub const deriveSecretSha256 = K.deriveSecretSha256;
        pub const deriveSecretSha384 = K.deriveSecretSha384;
        pub const finishedKey = K.finishedKey;
        pub const finishedKeySha256 = K.finishedKeySha256;
        pub const finishedKeySha384 = K.finishedKeySha384;
        pub const finishedVerifyData = K.finishedVerifyData;
        pub const finishedVerifyDataSha256 = K.finishedVerifyDataSha256;
        pub const finishedVerifyDataSha384 = K.finishedVerifyDataSha384;
        pub const hkdfExtractProfile = K.hkdfExtractProfile;
        pub const hkdfExpandLabelIntoProfile = K.hkdfExpandLabelIntoProfile;
        pub const deriveSecretProfile = K.deriveSecretProfile;
        pub const finishedVerifyDataProfile = K.finishedVerifyDataProfile;
        pub const tls12Prf = K.tls12Prf;
        pub const tls12PrfSha256 = K.tls12PrfSha256;

        pub const RecordError = R.RecordError;
        pub const ReadRecordResult = R.ReadRecordResult;
        pub const CipherState = R.CipherState;
        pub const AesGcmState = R.AesGcmState;
        pub const ChaChaState = R.ChaChaState;
        pub const RecordLayer = R.RecordLayer;

        pub const ClientHandshakeError = CH.HandshakeError;
        pub const HandshakeState = CH.HandshakeState;
        pub const VerificationMode = CH.VerificationMode;
        pub const InitOptions = CH.InitOptions;
        pub const KeyExchange = CH.KeyExchange;
        pub const X25519KeyExchange = CH.X25519KeyExchange;
        pub const ClientHandshake = CH.ClientHandshake;
        pub const ServerHandshakeError = SH.HandshakeError;
        pub const ServerHandshakeState = SH.HandshakeState;
        pub const ServerPrivateKey = SH.PrivateKey;
        pub const ServerCertificate = SH.Certificate;
        pub const ServerConfig = SC.Config;
        pub const ServerHandshake = SH.ServerHandshake;
        pub const Config = TC.Config;
        pub const Conn = TC;
        pub const ServerConn = SC;
        pub const Listener = TL;
        pub const Dialer = TlsDialer;
        pub const Network = TlsDialer.Network;
        pub const ListenOptions = NTL.Options;

        pub fn client(allocator: std.mem.Allocator, inner: NetConn, config: Config) TC.InitError!NetConn {
            return TC.init(allocator, inner, config);
        }

        pub fn server(allocator: std.mem.Allocator, inner: NetConn, config: ServerConfig) SC.InitError!NetConn {
            return SC.init(allocator, inner, config);
        }

        pub fn dial(
            allocator: std.mem.Allocator,
            network: Network,
            addr: netip.AddrPort,
            config: Config,
        ) !NetConn {
            const net_dialer = NetDialer.init(allocator, .{});
            const d = TlsDialer.init(net_dialer, config);
            return d.dial(network, addr);
        }

        pub fn dialContext(
            ctx: Context,
            allocator: std.mem.Allocator,
            network: Network,
            addr: netip.AddrPort,
            config: Config,
        ) !NetConn {
            const net_dialer = NetDialer.init(allocator, .{});
            const d = TlsDialer.init(net_dialer, config);
            return d.dialContext(ctx, network, addr);
        }

        pub fn newListener(allocator: std.mem.Allocator, inner: NetListener, config: ServerConfig) !NetListener {
            return TL.init(allocator, inner, config);
        }

        pub fn listen(allocator: std.mem.Allocator, opts: ListenOptions, config: ServerConfig) !NetListener {
            var inner = try NTL.init(allocator, opts);
            errdefer inner.deinit();
            var ln = try TL.init(allocator, inner, config);
            errdefer ln.deinit();
            try ln.listen();
            return ln;
        }
    };
}

pub fn TestRunner(comptime std: type, comptime net: type) @import("testing").TestRunner {
    const testing_api = @import("testing");

    const Runner = struct {
        pub fn init(self: *@This(), allocator: std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(_: *@This(), t: *testing_api.T, allocator: std.mem.Allocator) bool {
            _ = allocator;

            t.run("alert", alert.TestRunner(std));
            t.run("common", common.TestRunner(std));
            t.run("extensions", extensions.TestRunner(std));
            t.run("kdf", kdf.TestRunner(std));
            t.run("record", record.TestRunner(std));
            t.run("client_handshake", client_handshake.TestRunner(std, net.time));
            t.run("server_handshake", server_handshake.TestRunner(std, net.time));
            t.run("make2_conn_context", testing_api.TestRunner.fromFn(std, 2 * 1024 * 1024, struct {
                fn run(_: *testing_api.T, case_allocator: std.mem.Allocator) !void {
                    const net_root = @import("../net.zig");
                    const ContextApi = @import("context").make(std, net.time);
                    const runtime_mod = net_root.runtime;
                    const FakeRuntimeImpl = struct {
                        pub const Tcp = struct {
                            closed: bool = false,

                            pub fn close(self: *@This()) void {
                                self.closed = true;
                            }

                            pub fn deinit(self: *@This()) void {
                                _ = self;
                            }

                            pub fn shutdown(self: *@This(), how: runtime_mod.ShutdownHow) runtime_mod.SocketError!void {
                                _ = self;
                                _ = how;
                            }

                            pub fn signal(self: *@This(), ev: runtime_mod.SignalEvent) void {
                                _ = self;
                                _ = ev;
                            }

                            pub fn bind(self: *@This(), addr: net_root.netip.AddrPort) runtime_mod.SocketError!void {
                                _ = self;
                                _ = addr;
                            }

                            pub fn listen(self: *@This(), backlog: u31) runtime_mod.SocketError!void {
                                _ = self;
                                _ = backlog;
                            }

                            pub fn accept(self: *@This(), remote: ?*net_root.netip.AddrPort) runtime_mod.SocketError!Tcp {
                                _ = self;
                                _ = remote;
                                return error.Unexpected;
                            }

                            pub fn connect(self: *@This(), addr: net_root.netip.AddrPort) runtime_mod.SocketError!void {
                                _ = self;
                                _ = addr;
                            }

                            pub fn finishConnect(self: *@This()) runtime_mod.SocketError!void {
                                _ = self;
                            }

                            pub fn recv(self: *@This(), buf: []u8) runtime_mod.SocketError!usize {
                                _ = self;
                                _ = buf;
                                return error.Unexpected;
                            }

                            pub fn send(self: *@This(), buf: []const u8) runtime_mod.SocketError!usize {
                                _ = self;
                                _ = buf;
                                return error.Unexpected;
                            }

                            pub fn localAddr(self: *@This()) runtime_mod.SocketError!net_root.netip.AddrPort {
                                _ = self;
                                return net_root.netip.AddrPort.from4(.{ 0, 0, 0, 0 }, 0);
                            }

                            pub fn remoteAddr(self: *@This()) runtime_mod.SocketError!net_root.netip.AddrPort {
                                _ = self;
                                return net_root.netip.AddrPort.from4(.{ 0, 0, 0, 0 }, 0);
                            }

                            pub fn setOpt(self: *@This(), opt: runtime_mod.TcpOption) runtime_mod.SetSockOptError!void {
                                _ = self;
                                _ = opt;
                            }

                            pub fn poll(self: *@This(), want: runtime_mod.PollEvents, timeout: ?net.time.duration.Duration) runtime_mod.PollError!runtime_mod.PollEvents {
                                _ = self;
                                _ = want;
                                _ = timeout;
                                return error.Unexpected;
                            }
                        };

                        pub const Udp = struct {
                            closed: bool = false,

                            pub fn close(self: *@This()) void {
                                self.closed = true;
                            }

                            pub fn deinit(self: *@This()) void {
                                _ = self;
                            }

                            pub fn signal(self: *@This(), ev: runtime_mod.SignalEvent) void {
                                _ = self;
                                _ = ev;
                            }

                            pub fn bind(self: *@This(), addr: net_root.netip.AddrPort) runtime_mod.SocketError!void {
                                _ = self;
                                _ = addr;
                            }

                            pub fn connect(self: *@This(), addr: net_root.netip.AddrPort) runtime_mod.SocketError!void {
                                _ = self;
                                _ = addr;
                            }

                            pub fn finishConnect(self: *@This()) runtime_mod.SocketError!void {
                                _ = self;
                            }

                            pub fn recv(self: *@This(), buf: []u8) runtime_mod.SocketError!usize {
                                _ = self;
                                _ = buf;
                                return error.Unexpected;
                            }

                            pub fn recvFrom(self: *@This(), buf: []u8, src: ?*net_root.netip.AddrPort) runtime_mod.SocketError!usize {
                                _ = self;
                                _ = buf;
                                _ = src;
                                return error.Unexpected;
                            }

                            pub fn send(self: *@This(), buf: []const u8) runtime_mod.SocketError!usize {
                                _ = self;
                                _ = buf;
                                return error.Unexpected;
                            }

                            pub fn sendTo(self: *@This(), buf: []const u8, dst: net_root.netip.AddrPort) runtime_mod.SocketError!usize {
                                _ = self;
                                _ = buf;
                                _ = dst;
                                return error.Unexpected;
                            }

                            pub fn localAddr(self: *@This()) runtime_mod.SocketError!net_root.netip.AddrPort {
                                _ = self;
                                return net_root.netip.AddrPort.from4(.{ 0, 0, 0, 0 }, 0);
                            }

                            pub fn remoteAddr(self: *@This()) runtime_mod.SocketError!net_root.netip.AddrPort {
                                _ = self;
                                return net_root.netip.AddrPort.from4(.{ 0, 0, 0, 0 }, 0);
                            }

                            pub fn setOpt(self: *@This(), opt: runtime_mod.UdpOption) runtime_mod.SetSockOptError!void {
                                _ = self;
                                _ = opt;
                            }

                            pub fn poll(self: *@This(), want: runtime_mod.PollEvents, timeout: ?net.time.duration.Duration) runtime_mod.PollError!runtime_mod.PollEvents {
                                _ = self;
                                _ = want;
                                _ = timeout;
                                return error.Unexpected;
                            }
                        };

                        pub fn tcp(domain: runtime_mod.Domain) runtime_mod.CreateError!Tcp {
                            _ = domain;
                            return .{};
                        }

                        pub fn udp(domain: runtime_mod.Domain) runtime_mod.CreateError!Udp {
                            _ = domain;
                            return .{};
                        }
                    };
                    const FakeNet = net_root.make(std, net.time, FakeRuntimeImpl);

                    var ctx_api = try ContextApi.init(case_allocator);
                    defer ctx_api.deinit();

                    var io_ctx = try ctx_api.withCancel(ctx_api.background());
                    defer io_ctx.deinit();

                    const socket = try FakeNet.Runtime.tcp(.inet);
                    var inner = try FakeNet.TcpConn.initFromSocket(case_allocator, socket);
                    errdefer inner.deinit();

                    var tls_conn = try FakeNet.tls.client(case_allocator, inner, .{
                        .server_name = "example.com",
                        .insecure_skip_verify = true,
                    });
                    defer tls_conn.deinit();

                    const typed_tls = try tls_conn.as(FakeNet.tls.Conn);
                    const typed_tcp = try typed_tls.inner.as(FakeNet.TcpConn);

                    try typed_tls.setReadContext(io_ctx);
                    try typed_tls.setWriteContext(io_ctx);
                    try std.testing.expect(typed_tcp.read_ctx != null);
                    try std.testing.expect(typed_tcp.write_ctx != null);

                    try typed_tls.setReadContext(null);
                    try typed_tls.setWriteContext(null);
                    try std.testing.expect(typed_tcp.read_ctx == null);
                    try std.testing.expect(typed_tcp.write_ctx == null);
                }
            }.run));
            t.run("Conn", conn_impl.TestRunner(std, net));
            t.run("ServerConn", server_conn_impl.TestRunner(std, net));
            return t.wait();
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}
