const std = @import("std");
const testing = std.testing;
const module = @import("src.zig");
const test_exports = if (@hasDecl(module, "test_exports")) module.test_exports else struct {};
const Error = module.Error;
const Application = module.Application;
const Signal = module.Signal;
const Bandwidth = module.Bandwidth;
const Encoder = module.Encoder;
const Decoder = module.Decoder;
const getVersionString = module.getVersionString;
const packetGetSamples = module.packetGetSamples;
const packetGetChannels = module.packetGetChannels;
const packetGetBandwidth = module.packetGetBandwidth;
const packetGetFrames = module.packetGetFrames;
const checkError = test_exports.checkError;
const OPUS_BAD_ARG = test_exports.OPUS_BAD_ARG;
const OPUS_INVALID_STATE = test_exports.OPUS_INVALID_STATE;

test "maps opus negative code to typed error" {
    try std.testing.expectError(Error.BadArg, checkError(OPUS_BAD_ARG));
    try std.testing.expectError(Error.InvalidState, checkError(OPUS_INVALID_STATE));
}

test "accepts non-negative return codes" {
    try checkError(0);
    try checkError(3);
}
