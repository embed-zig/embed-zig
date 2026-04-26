const embed = @import("embed");
const binding = @import("binding.zig");
const opus_error = @import("error.zig");
const types = @import("types.zig");

pub const Error = types.Error;
pub const Bandwidth = types.Bandwidth;

pub fn getSamples(data: []const u8, sample_rate: u32) Error!u32 {
    try validatePacketData(data);
    return @intCast(try opus_error.checkedPositive(binding.opus_packet_get_nb_samples(
        data.ptr,
        @intCast(data.len),
        @intCast(sample_rate),
    )));
}

pub fn getChannels(data: []const u8) Error!u8 {
    try validatePacketData(data);
    return @intCast(try opus_error.checkedPositive(binding.opus_packet_get_nb_channels(data.ptr)));
}

pub fn getBandwidth(data: []const u8) Error!Bandwidth {
    try validatePacketData(data);
    const ret = binding.opus_packet_get_bandwidth(data.ptr);
    try opus_error.checkError(ret);
    return @enumFromInt(ret);
}

pub fn getFrames(data: []const u8) Error!u32 {
    try validatePacketData(data);
    return @intCast(try opus_error.checkedPositive(binding.opus_packet_get_nb_frames(data.ptr, @intCast(data.len))));
}

fn validatePacketData(data: []const u8) Error!void {
    if (data.len == 0) return Error.InvalidPacket;
}

pub fn TestRunner(comptime lib: type) @import("testing").TestRunner {
    const testing_api = @import("testing");

    const TestCase = struct {
        fn helpersInspectEncodedFrame() !void {
            const Encoder = @import("Encoder.zig");
            const opus = @import("../../opus.zig");

            var encoder = try Encoder.init(lib.testing.allocator, 48_000, 1, .audio);
            defer encoder.deinit(lib.testing.allocator);

            const pcm = [_]i16{0} ** 960;
            var out: [1500]u8 = undefined;
            const encoded = try encoder.encode(pcm[0..], 960, out[0..]);

            try lib.testing.expect(encoded.len > 0);
            try lib.testing.expectEqual(@as(u8, 1), try getChannels(encoded));
            try lib.testing.expectEqual(@as(u32, 1), try getFrames(encoded));
            try lib.testing.expectEqual(@as(u32, 960), try getSamples(encoded, 48_000));
            try lib.testing.expectEqual(try opus.packetGetChannels(encoded), try getChannels(encoded));
            try lib.testing.expectEqual(try opus.packetGetFrames(encoded), try getFrames(encoded));
            try lib.testing.expectEqual(try opus.packetGetSamples(encoded, 48_000), try getSamples(encoded, 48_000));
            try lib.testing.expectEqual(try opus.packetGetBandwidth(encoded), try getBandwidth(encoded));

            switch (try getBandwidth(encoded)) {
                .auto,
                .narrowband,
                .mediumband,
                .wideband,
                .superwideband,
                .fullband,
                => {},
            }
        }

        fn helpersRejectEmptyInput() !void {
            const empty = [_]u8{};

            try lib.testing.expectError(Error.InvalidPacket, getChannels(empty[0..]));
            try lib.testing.expectError(Error.InvalidPacket, getFrames(empty[0..]));
            try lib.testing.expectError(Error.InvalidPacket, getSamples(empty[0..], 48_000));
            try lib.testing.expectError(Error.InvalidPacket, getBandwidth(empty[0..]));
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            TestCase.helpersInspectEncodedFrame() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.helpersRejectEmptyInput() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: lib.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}
