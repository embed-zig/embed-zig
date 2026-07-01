//! audio.Mic — type-erased microphone role surface.

const drivers = @import("drivers");
const glib = @import("glib");
const AudioSystem = @import("AudioSystem.zig");
const I2sMicAdapter = @import("i2s/Mic.zig");

pub const Error = AudioSystem.Error;

pub fn make(comptime grt: type, comptime mic_count: usize, comptime samples_per_channel: usize) type {
    return struct {
        const Self = @This();

        pub const Frame = struct {
            mic: [mic_count][samples_per_channel]i16,
            ref: ?[samples_per_channel]i16 = null,
        };
        pub const Gains = [mic_count]?i8;
        pub const frame_mic_count: usize = mic_count;
        pub const frame_samples_per_channel: usize = samples_per_channel;
        pub const GainTableFunc = *const fn (gain_db: i8) i8;

        pub const I2s = I2sMicAdapter.make(grt, mic_count, samples_per_channel, Self);
        pub const I2sConfig = I2s.Config;

        ptr: *anyopaque,
        vtable: *const VTable,
        gain_table_func: ?GainTableFunc = null,

        pub const VTable = struct {
            deinit: *const fn (ptr: *anyopaque) void,

            sampleRate: *const fn (ptr: *anyopaque) u32,
            micCount: *const fn (ptr: *anyopaque) u8,
            hasRef: *const fn (ptr: *anyopaque) bool = noRef,

            read: *const fn (ptr: *anyopaque, frame: *Frame) Error!void,

            gains: *const fn (ptr: *anyopaque) Gains,
            setGains: *const fn (ptr: *anyopaque, gains_db: []const ?i8) Error!void,

            enable: *const fn (ptr: *anyopaque) Error!void,
            disable: *const fn (ptr: *anyopaque) Error!void,
        };

        fn noRef(_: *anyopaque) bool {
            return false;
        }

        pub fn init(ptr: *anyopaque, vtable: *const VTable) Self {
            return .{
                .ptr = ptr,
                .vtable = vtable,
            };
        }

        pub fn setGainTableFunc(self: *Self, gain_table_func: ?GainTableFunc) void {
            self.gain_table_func = gain_table_func;
        }

        pub fn i2s(config: I2sConfig) I2s {
            return I2s.init(config);
        }

        pub fn deinit(self: Self) void {
            self.vtable.deinit(self.ptr);
        }

        pub fn sampleRate(self: Self) u32 {
            return self.vtable.sampleRate(self.ptr);
        }

        pub fn micCount(self: Self) u8 {
            return self.vtable.micCount(self.ptr);
        }

        pub fn hasRef(self: Self) bool {
            return self.vtable.hasRef(self.ptr);
        }

        pub fn read(self: Self, frame: *Frame) Error!void {
            return self.vtable.read(self.ptr, frame);
        }

        pub fn gains(self: Self) Gains {
            return self.vtable.gains(self.ptr);
        }

        pub fn setGains(self: Self, gains_db: []const ?i8) Error!void {
            const gain_table_func = self.gain_table_func orelse {
                return self.vtable.setGains(self.ptr, gains_db);
            };
            if (gains_db.len > mic_count) return error.Unsupported;

            var mapped_gains: Gains = [_]?i8{null} ** mic_count;
            for (gains_db, 0..) |gain_db, index| {
                mapped_gains[index] = if (gain_db) |value| gain_table_func(value) else null;
            }
            return self.vtable.setGains(self.ptr, mapped_gains[0..gains_db.len]);
        }

        pub fn enable(self: Self) Error!void {
            return self.vtable.enable(self.ptr);
        }

        pub fn disable(self: Self) Error!void {
            return self.vtable.disable(self.ptr);
        }
    };
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn i2sAdapterSplitsRawFramesIntoMicFrame(allocator: glib.std.mem.Allocator) !void {
            const TestMic = make(grt, 2, 2);
            const FakeI2s = struct {
                read_fill: [16]u8 = .{
                    1, 0, 10, 0, 20, 0, 30, 0,
                    2, 0, 11, 0, 21, 0, 31, 0,
                },

                pub fn write(_: *@This(), data: []const u8) drivers.I2s.Error!usize {
                    return data.len;
                }

                pub fn read(self: *@This(), buf: []u8) drivers.I2s.Error!usize {
                    @memcpy(buf, self.read_fill[0..buf.len]);
                    return buf.len;
                }
            };

            var fake_i2s = FakeI2s{};
            var stream = try drivers.I2s.init(allocator, &fake_i2s, .{
                .slots_per_frame = 4,
                .bytes_per_slot = 2,
                .buffer_frame_count = 2,
            });
            defer stream.deinit();

            var capture = TestMic.i2s(.{
                .stream = &stream,
                .sample_rate = 16_000,
                .mic_channels = .{
                    .{ .slot = 1 },
                    .{ .slot = 3 },
                },
                .ref_channel = .{ .slot = 0 },
            });
            const mic = capture.mic();

            try grt.std.testing.expectEqual(@as(u32, 16_000), mic.sampleRate());
            try grt.std.testing.expectEqual(@as(u8, 2), mic.micCount());
            try mic.enable();

            var frame: TestMic.Frame = undefined;
            try mic.read(&frame);

            try grt.std.testing.expectEqualSlices(i16, &.{ 10, 11 }, frame.mic[0][0..]);
            try grt.std.testing.expectEqualSlices(i16, &.{ 30, 31 }, frame.mic[1][0..]);
            const ref = frame.ref.?;
            try grt.std.testing.expectEqualSlices(i16, &.{ 1, 2 }, ref[0..]);
        }

        fn i2sAdapterRejectsReadBeforeEnable(allocator: glib.std.mem.Allocator) !void {
            const TestMic = make(grt, 1, 1);
            const FakeI2s = struct {
                pub fn write(_: *@This(), data: []const u8) drivers.I2s.Error!usize {
                    return data.len;
                }

                pub fn read(_: *@This(), buf: []u8) drivers.I2s.Error!usize {
                    return buf.len;
                }
            };

            var fake_i2s = FakeI2s{};
            var stream = try drivers.I2s.init(allocator, &fake_i2s, .{
                .slots_per_frame = 1,
                .bytes_per_slot = 2,
                .buffer_frame_count = 1,
            });
            defer stream.deinit();

            var capture = TestMic.i2s(.{
                .stream = &stream,
                .sample_rate = 16_000,
                .mic_channels = .{
                    .{ .slot = 0 },
                },
            });
            const mic = capture.mic();
            var frame: TestMic.Frame = undefined;

            try grt.std.testing.expectError(error.InvalidState, mic.read(&frame));
        }

        fn i2sAdapterMapsGainsWithTableFunc(allocator: glib.std.mem.Allocator) !void {
            const TestMic = make(grt, 2, 1);
            const FakeI2s = struct {
                pub fn write(_: *@This(), data: []const u8) drivers.I2s.Error!usize {
                    return data.len;
                }

                pub fn read(_: *@This(), buf: []u8) drivers.I2s.Error!usize {
                    return buf.len;
                }
            };
            const GainTable = struct {
                fn lower(gain_db: i8) i8 {
                    return gain_db - 6;
                }
            };

            var fake_i2s = FakeI2s{};
            var stream = try drivers.I2s.init(allocator, &fake_i2s, .{
                .slots_per_frame = 2,
                .bytes_per_slot = 2,
                .buffer_frame_count = 1,
            });
            defer stream.deinit();

            var capture = TestMic.i2s(.{
                .stream = &stream,
                .sample_rate = 16_000,
                .mic_channels = .{
                    .{ .slot = 0 },
                    .{ .slot = 1 },
                },
            });
            var mic = capture.mic();

            mic.setGainTableFunc(&GainTable.lower);
            try mic.setGains(&.{ 10, null });
            try grt.std.testing.expectEqual(TestMic.Gains{ 4, null }, mic.gains());

            try mic.setGains(&.{ null, 8 });
            try grt.std.testing.expectEqual(TestMic.Gains{ 4, 2 }, mic.gains());

            mic.setGainTableFunc(null);
            try mic.setGains(&.{ 12, null });
            try grt.std.testing.expectEqual(TestMic.Gains{ 12, 2 }, mic.gains());
        }

        fn i2sAdapterExtractsWideSlotSamples(allocator: glib.std.mem.Allocator) !void {
            const TestMic = make(grt, 1, 2);
            const FakeI2s = struct {
                read_fill: [16]u8 = .{
                    0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0xFE, 0xFF,
                    0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x34, 0x12,
                },

                pub fn write(_: *@This(), data: []const u8) drivers.I2s.Error!usize {
                    return data.len;
                }

                pub fn read(self: *@This(), buf: []u8) drivers.I2s.Error!usize {
                    @memcpy(buf, self.read_fill[0..buf.len]);
                    return buf.len;
                }
            };

            var fake_i2s = FakeI2s{};
            var stream = try drivers.I2s.init(allocator, &fake_i2s, .{
                .slots_per_frame = 2,
                .bytes_per_slot = 4,
                .buffer_frame_count = 2,
            });
            defer stream.deinit();

            var capture = TestMic.i2s(.{
                .stream = &stream,
                .sample_rate = 16_000,
                .mic_channels = .{
                    .{ .slot = 1, .sample_align = .msb },
                },
                .ref_channel = .{ .slot = 0, .sample_align = .msb },
            });
            const mic = capture.mic();

            try mic.enable();
            var frame: TestMic.Frame = undefined;
            try mic.read(&frame);

            try grt.std.testing.expectEqualSlices(i16, &.{ -2, 0x1234 }, frame.mic[0][0..]);
            const ref = frame.ref.?;
            try grt.std.testing.expectEqualSlices(i16, &.{ 1, 2 }, ref[0..]);
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;
            TestCase.i2sAdapterSplitsRawFramesIntoMicFrame(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.i2sAdapterRejectsReadBeforeEnable(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.i2sAdapterMapsGainsWithTableFunc(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.i2sAdapterExtractsWideSlotSamples(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: glib.std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return glib.testing.TestRunner.make(Runner).new(&Holder.runner);
}
