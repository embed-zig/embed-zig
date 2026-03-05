pub const transport = @import("transport.zig");
pub const client = @import("client.zig");

pub const request = @import("request.zig");
pub const response = @import("response.zig");
pub const router = @import("router.zig");
pub const static = @import("static.zig");
pub const server_mod = @import("server.zig");

// Transport layer
pub const RoundTripper = transport.RoundTripper;
pub const Transport = transport.Transport;
pub const RoundTripRequest = transport.RoundTripRequest;
pub const RoundTripResponse = transport.RoundTripResponse;
pub const TransportError = transport.TransportError;
pub const Scheme = transport.Scheme;
pub const requestFromUrl = transport.requestFromUrl;

// Client
pub const Client = client.Client;

// Server
pub const Server = server_mod.Server;
pub const ServerConfig = server_mod.Config;

// Request/Response types
pub const Request = request.Request;
pub const Method = request.Method;
pub const HeaderIterator = request.HeaderIterator;
pub const ParseError = request.ParseError;

pub const Response = response.Response;
pub const statusText = response.statusText;

// Router
pub const Route = router.Route;
pub const Handler = router.Handler;
pub const MatchType = router.MatchType;
pub const get = router.get;
pub const post = router.post;
pub const put = router.put;
pub const delete = router.delete;
pub const prefix = router.prefix;

// Static files
pub const EmbeddedFile = static.EmbeddedFile;
pub const mimeFromPath = static.mimeFromPath;

test {
    _ = transport;
    _ = client;
    _ = request;
    _ = response;
    _ = router;
    _ = static;
    _ = server_mod;
}
