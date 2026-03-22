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
const NetConn = @import("Conn.zig");
const NetListener = @import("Listener.zig");
const tcp_listener = @import("TcpListener.zig");

pub fn Make(comptime lib: type) type {
    const C = common.Make(lib);
    const A = alert.Make(lib);
    const E = extensions.Make(lib);
    const K = kdf.Make(lib);
    const R = record.Make(lib);
    const CH = client_handshake.Make(lib);
    const SH = server_handshake.Make(lib);
    const TC = conn_impl.Conn(lib);
    const SC = server_conn_impl.ServerConn(lib);
    const TL = listener_impl.Listener(lib);
    const TD = dialer_impl.Dialer(lib);
    const NTL = tcp_listener.TcpListener(lib);

    return struct {
        pub const ProtocolVersion = C.ProtocolVersion;
        pub const ContentType = C.ContentType;
        pub const HandshakeType = C.HandshakeType;
        pub const CipherSuite = C.CipherSuite;
        pub const Tls13Hash = C.Tls13Hash;
        pub const Tls13CipherProfile = C.Tls13CipherProfile;
        pub const DEFAULT_TLS13_CIPHER_SUITES = C.DEFAULT_TLS13_CIPHER_SUITES;
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
        pub const Dialer = TD;
        pub const Network = TD.Network;
        pub const ListenOptions = NTL.Options;

        pub fn client(allocator: lib.mem.Allocator, inner: NetConn, config: Config) TC.InitError!NetConn {
            return TC.init(allocator, inner, config);
        }

        pub fn server(allocator: lib.mem.Allocator, inner: NetConn, config: ServerConfig) SC.InitError!NetConn {
            return SC.init(allocator, inner, config);
        }

        pub fn dial(
            allocator: lib.mem.Allocator,
            network: Network,
            addr: lib.net.Address,
            config: Config,
        ) !NetConn {
            const net_dialer = @import("Dialer.zig").Dialer(lib).init(allocator, .{});
            const d = TD.init(net_dialer, config);
            return d.dial(network, addr);
        }

        pub fn newListener(allocator: lib.mem.Allocator, inner: NetListener, config: ServerConfig) !NetListener {
            return TL.init(allocator, inner, config);
        }

        pub fn listen(allocator: lib.mem.Allocator, opts: ListenOptions, config: ServerConfig) !NetListener {
            var inner = try NTL.init(allocator, opts);
            errdefer inner.deinit();
            return TL.init(allocator, inner, config);
        }
    };
}

test {
    _ = @import("tls/common.zig");
    _ = @import("tls/alert.zig");
    _ = @import("tls/extensions.zig");
    _ = @import("tls/kdf.zig");
    _ = @import("tls/record.zig");
    _ = @import("tls/client_handshake.zig");
    _ = @import("tls/server_handshake.zig");
    _ = @import("tls/Conn.zig");
    _ = @import("tls/ServerConn.zig");
    _ = @import("tls/Listener.zig");
    _ = @import("tls/Dialer.zig");
}

