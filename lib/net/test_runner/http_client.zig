//! HTTP client local runner — local HTTP client coverage.

const shared = @import("http_transport.zig");
const testing_api = @import("testing");

pub fn make(comptime lib: type) testing_api.TestRunner {
    return shared.make(lib, "http_client", cases);
}

fn cases(comptime lib: type, comptime Runner: type) !void {
    _ = lib;
    try Runner.clientLocalReturns200();
    try Runner.clientHeadResponseIsBodyless();
    try Runner.clientFollowsRedirect();
    try Runner.clientCloseIdleConnectionsForcesNewConn();
    try Runner.clientDeinitWaitsForResponseDeinit();
}
