//! HTTP transport layer01 runner — focused keep-alive/reuse transport coverage.

const shared = @import("http_transport.zig");
const testing_api = @import("testing");

pub fn make(comptime lib: type) testing_api.TestRunner {
    return shared.make(lib, "http_transport_layer01", cases);
}

fn cases(comptime lib: type, comptime Runner: type) !void {
    _ = lib;
    try Runner.idleConnectionIsReused();
    try Runner.closeIdleConnectionsForcesNewConn();
    try Runner.earlyResponseBodyCloseDoesNotReuseConn();
    try Runner.idleConnectionTimeoutForcesNewConn();
    try Runner.sameHostRequestWhileBodyOpenUsesSecondConn();
    try Runner.defaultUserAgentMatches();
    try Runner.emptyUserAgentSuppressesDefault();
    try Runner.responseHeaderTimeoutExceeded();
    try Runner.responseHeaderTimeoutDoesNotLimitBodyRead();
    try Runner.configuredMaxHeaderBytesAllowsLargeResponseHeaders();
    try Runner.defaultMaxBodyBytesAllowsLargeResponse();
    try Runner.defaultMaxBodyBytesAllowsLargeRequest();
    try Runner.informationalContinueThenFinalResponse();
    try Runner.expectContinueTimeoutSendsBodyWithoutInformational();
    try Runner.finalResponseWithoutContinueSkipsRequestBody();
    try Runner.staleIdleConnectionRetriesReplayableGet();
    try Runner.staleIdleConnectionRetriesIdempotentReplayablePost();
}
