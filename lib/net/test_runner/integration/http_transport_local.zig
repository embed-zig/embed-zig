//! HTTP transport local runner — local HTTP transport coverage.

const shared = @import("http_transport.zig");
const testing_api = @import("testing");

pub fn make(comptime lib: type) testing_api.TestRunner {
    return shared.make(lib, "http_transport", cases);
}

fn cases(comptime lib: type, comptime Runner: type) !void {
    _ = lib;
    try Runner.localReturns200();
    try Runner.localReturns404();
    try Runner.defaultUserAgentMatches();
    try Runner.emptyUserAgentSuppressesDefault();
    try Runner.contextDeadlineExceeded();
    try Runner.responseHeaderTimeoutExceeded();
    try Runner.responseHeaderTimeoutDoesNotLimitBodyRead();
    try Runner.responseBodyReadCanceledByContext();
    try Runner.responseBodyReadDeadlineExceededByContext();
    try Runner.requestBodyWriteCanceledByContext();
    try Runner.requestBodyWriteDeadlineExceededByContext();
    try Runner.chunkedRequestBodyWriteCanceledByContext();
    try Runner.chunkedRequestBodyWriteDeadlineExceededByContext();
    try Runner.configuredMaxHeaderBytesAllowsLargeResponseHeaders();
    try Runner.responseBodyLargerThanMaxBodyBytesFails();
    try Runner.defaultMaxBodyBytesAllowsLargeResponse();
    try Runner.largeResponseStreamsWithoutBufferingWholeBody();
    try Runner.defaultMaxBodyBytesAllowsLargeRequest();
    try Runner.largeRequestStreamsWithoutBufferingWholeBody();
    try Runner.connectMethodIsRejected();
    try Runner.httpsConnectProxyAuthRequired();
    try Runner.httpsConnectProxyAuthRequiredWithBody();
    try Runner.httpsConnectProxyRejected();
    try Runner.httpsConnectProxyRejectedWithBody();
    try Runner.httpsConnectProxyResponseHeaderTimeout();
    try Runner.httpsConnectProxyTlsInitFailureClosesTunnelConn();
    try Runner.httpsProxyUserinfoGeneratesProxyAuthorization();
    try Runner.httpsProxyInvalidPercentEncodingIsRejected();
    try Runner.httpsProxyOversizedUserinfoIsRejected();
    try Runner.httpsProxyConnectHeadersOverrideUrlUserinfo();
    try Runner.idleConnectionIsReused();
    try Runner.disableKeepAlivesForcesNewConn();
    try Runner.maxIdleConnsOneKeepsOnlyOneIdleConnAcrossHosts();
    try Runner.maxIdleConnsPerHostOneKeepsOnlyOneIdleConn();
    try Runner.closeIdleConnectionsForcesNewConn();
    try Runner.earlyResponseBodyCloseDoesNotReuseConn();
    try Runner.idleConnectionTimeoutForcesNewConn();
    try Runner.sameHostRequestWhileBodyOpenUsesSecondConn();
    try Runner.maxConnsPerHostOneBlocksSecondRequestUntilFirstResponseCloses();
    try Runner.maxConnsPerHostTwoAllowsSecondLiveConn();
    try Runner.maxConnsPerHostWaiterReusesReturnedIdleConn();
    try Runner.maxConnsPerHostWaiterDeadlineExceeded();
    try Runner.maxConnsPerHostWaiterCanceled();
    try Runner.closeIdleConnectionsWithMaxConnsPerHostDoesNotLeakCapacity();
    try Runner.chunkedRequestUsesTransferEncoding();
    try Runner.chunkedResponseStreams();
    try Runner.eofDelimitedResponseStreams();
    try Runner.headResponseIsBodyless();
    try Runner.status204ResponseIsBodyless();
    try Runner.status304ResponseIsBodyless();
    try Runner.informationalContinueThenFinalResponse();
    try Runner.expectContinueTimeoutSendsBodyWithoutInformational();
    try Runner.finalResponseWithoutContinueSkipsRequestBody();
    try Runner.requestBodyStreamsBeforeRoundTripCompletes();
    try Runner.responseBodyStreamsProgressively();
    try Runner.fullDuplexRequestAndResponse();
    try Runner.bodylessEarlyResponseDoesNotWaitForBlockedRequestBody();
    try Runner.staleIdleConnectionRetriesReplayableGet();
    try Runner.staleIdleConnectionRetriesIdempotentReplayablePost();
}
