//! audio.Speaker — type-erased speaker role surface.

const drivers = @import("drivers");
const glib = @import("glib");
const AudioSystem = @import("AudioSystem.zig");
const I2sSpeakerAdapter = @import("i2s/Speaker.zig");

pub const Error = AudioSystem.Error;

pub fn make(comptime grt: type, comptime samples_per_channel: usize) type {
    return struct {
        const Self = @This();

        pub const Error = AudioSystem.Error;
        pub const Frame = [samples_per_channel]i16;
        pub const frame_samples_per_channel: usize = samples_per_channel;
        pub const GainTableFunc = *const fn (gain_db: i8) i8;

        pub const I2s = I2sSpeakerAdapter.make(grt, samples_per_channel, Self);
        pub const I2sConfig = I2s.Config;

        ptr: *anyopaque,
        vtable: *const VTable,
        gain_table_func: ?GainTableFunc = null,

        pub const VTable = struct {
            deinit: *const fn (ptr: *anyopaque) void,

            sampleRate: *const fn (ptr: *anyopaque) u32,

            write: *const fn (ptr: *anyopaque, frame: []const i16) AudioSystem.Error!usize,

            gain: *const fn (ptr: *anyopaque) ?i8,
            setGain: *const fn (ptr: *anyopaque, gain_db: i8) AudioSystem.Error!void,

            enable: *const fn (ptr: *anyopaque) AudioSystem.Error!void,
            disable: *const fn (ptr: *anyopaque) AudioSystem.Error!void,
        };

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

        pub fn write(self: Self, frame: []const i16) AudioSystem.Error!usize {
            return self.vtable.write(self.ptr, frame);
        }

        pub fn gain(self: Self) ?i8 {
            return self.vtable.gain(self.ptr);
        }

        pub fn setGain(self: Self, gain_db: i8) AudioSystem.Error!void {
            const mapped_gain_db = if (self.gain_table_func) |mapGain| mapGain(gain_db) else gain_db;
            return self.vtable.setGain(self.ptr, mapped_gain_db);
        }

        pub fn enable(self: Self) AudioSystem.Error!void {
            return self.vtable.enable(self.ptr);
        }

        pub fn disable(self: Self) AudioSystem.Error!void {
            return self.vtable.disable(self.ptr);
        }
    };
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn i2sAdapterWritesSamplesDirectly(allocator: glib.std.mem.Allocator) !void {
            const TestSpeaker = make(grt, 2);
            const FakeI2s = struct {
                last_write: [4]u8 = [_]u8{0} ** 4,
                last_write_len: usize = 0,

                pub fn write(self: *@This(), data: []const u8) drivers.I2s.Error!usize {
                    self.last_write_len = data.len;
                    @memcpy(self.last_write[0..data.len], data);
                    return data.len;
                }

                pub fn read(_: *@This(), buf: []u8) drivers.I2s.Error!usize {
                    return buf.len;
                }
            };

            const slots = [_]TestSpeaker.I2s.Slot{
                .{ .index = 0 },
            };
            const channels = [_]TestSpeaker.I2s.Channel{
                .{ .slots = &slots },
            };

            var fake_i2s = FakeI2s{};
            var stream = try drivers.I2s.init(allocator, &fake_i2s, .{
                .slots_per_frame = 1,
                .bytes_per_slot = 2,
                .buffer_frame_count = 2,
            });
            defer stream.deinit();

            var output = TestSpeaker.i2s(.{
                .stream = &stream,
                .sample_rate = 16_000,
                .channels = &channels,
            });
            const speaker = output.speaker();

            try grt.std.testing.expectEqual(@as(u32, 16_000), speaker.sampleRate());
            try speaker.enable();
            const written = try speaker.write(&.{ 0x1234, -2 });

            try grt.std.testing.expectEqual(@as(usize, 2), written);
            try grt.std.testing.expectEqual(@as(usize, 4), fake_i2s.last_write_len);
            try grt.std.testing.expectEqualSlices(u8, &.{
                0x34, 0x12, 0xFE, 0xFF,
            }, fake_i2s.last_write[0..4]);
        }

        fn i2sAdapterRejectsWriteBeforeEnable(allocator: glib.std.mem.Allocator) !void {
            const TestSpeaker = make(grt, 1);
            const FakeI2s = struct {
                pub fn write(_: *@This(), data: []const u8) drivers.I2s.Error!usize {
                    return data.len;
                }

                pub fn read(_: *@This(), buf: []u8) drivers.I2s.Error!usize {
                    return buf.len;
                }
            };

            const slots = [_]TestSpeaker.I2s.Slot{
                .{ .index = 0 },
            };
            const channels = [_]TestSpeaker.I2s.Channel{
                .{ .slots = &slots },
            };

            var fake_i2s = FakeI2s{};
            var stream = try drivers.I2s.init(allocator, &fake_i2s, .{
                .slots_per_frame = 1,
                .bytes_per_slot = 2,
                .buffer_frame_count = 1,
            });
            defer stream.deinit();

            var output = TestSpeaker.i2s(.{
                .stream = &stream,
                .sample_rate = 16_000,
                .channels = &channels,
            });
            const speaker = output.speaker();

            try grt.std.testing.expectError(error.InvalidState, speaker.write(&.{1}));
        }

        fn i2sAdapterMapsGainWithTableFunc(allocator: glib.std.mem.Allocator) !void {
            const TestSpeaker = make(grt, 1);
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
                    return gain_db - 12;
                }
            };

            const slots = [_]TestSpeaker.I2s.Slot{
                .{ .index = 0 },
            };
            const channels = [_]TestSpeaker.I2s.Channel{
                .{ .slots = &slots },
            };

            var fake_i2s = FakeI2s{};
            var stream = try drivers.I2s.init(allocator, &fake_i2s, .{
                .slots_per_frame = 1,
                .bytes_per_slot = 2,
                .buffer_frame_count = 1,
            });
            defer stream.deinit();

            var output = TestSpeaker.i2s(.{
                .stream = &stream,
                .sample_rate = 16_000,
                .channels = &channels,
            });
            var speaker = output.speaker();

            speaker.setGainTableFunc(&GainTable.lower);
            try speaker.setGain(3);
            try grt.std.testing.expectEqual(@as(?i8, -9), speaker.gain());

            speaker.setGainTableFunc(null);
            try speaker.setGain(3);
            try grt.std.testing.expectEqual(@as(?i8, 3), speaker.gain());
        }

        fn i2sAdapterExpandsMonoSamplesToWideSlots(allocator: glib.std.mem.Allocator) !void {
            const TestSpeaker = make(grt, 3);
            const FakeI2s = struct {
                writes: [24]u8 = [_]u8{0} ** 24,
                write_len: usize = 0,

                pub fn write(self: *@This(), data: []const u8) drivers.I2s.Error!usize {
                    @memcpy(self.writes[self.write_len..][0..data.len], data);
                    self.write_len += data.len;
                    return data.len;
                }

                pub fn read(_: *@This(), buf: []u8) drivers.I2s.Error!usize {
                    return buf.len;
                }
            };

            const slots = [_]TestSpeaker.I2s.Slot{
                .{ .index = 0, .sample_align = .msb },
                .{ .index = 1, .sample_align = .msb },
            };
            const channels = [_]TestSpeaker.I2s.Channel{
                .{ .slots = &slots },
            };

            var fake_i2s = FakeI2s{};
            var stream = try drivers.I2s.init(allocator, &fake_i2s, .{
                .slots_per_frame = 2,
                .bytes_per_slot = 4,
                .buffer_frame_count = 2,
            });
            defer stream.deinit();

            var output = TestSpeaker.i2s(.{
                .stream = &stream,
                .sample_rate = 16_000,
                .channels = &channels,
            });
            const speaker = output.speaker();

            try speaker.enable();
            const written = try speaker.write(&.{ 0x1234, -2, 0x0102 });

            try grt.std.testing.expectEqual(@as(usize, 3), written);
            try grt.std.testing.expectEqual(@as(usize, 24), fake_i2s.write_len);
            try grt.std.testing.expectEqualSlices(u8, &.{
                0x00, 0x00, 0x34, 0x12, 0x00, 0x00, 0x34, 0x12,
                0x00, 0x00, 0xFE, 0xFF, 0x00, 0x00, 0xFE, 0xFF,
                0x00, 0x00, 0x02, 0x01, 0x00, 0x00, 0x02, 0x01,
            }, fake_i2s.writes[0..24]);
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;
            TestCase.i2sAdapterWritesSamplesDirectly(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.i2sAdapterRejectsWriteBeforeEnable(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.i2sAdapterMapsGainWithTableFunc(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.i2sAdapterExpandsMonoSamplesToWideSlots(allocator) catch |err| {
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
