//! audio.Mic — type-erased microphone role surface.

const AudioSystem = @import("AudioSystem.zig");

const root = @This();

pub const Error = AudioSystem.Error;

pub fn make(comptime lib: type, comptime mic_count: usize, comptime samples_per_channel: usize) type {
    _ = lib;

    return struct {
        const Self = @This();

        pub const Frame = struct {
            mic: [mic_count][samples_per_channel]i16,
            ref: ?[samples_per_channel]i16 = null,
        };
        pub const Gains = [mic_count]?i8;
        pub const frame_mic_count: usize = mic_count;
        pub const frame_samples_per_channel: usize = samples_per_channel;

        ptr: *anyopaque,
        vtable: *const VTable,

        pub const VTable = struct {
            deinit: *const fn (ptr: *anyopaque) void,

            sampleRate: *const fn (ptr: *anyopaque) u32,
            micCount: *const fn (ptr: *anyopaque) u8,

            read: *const fn (ptr: *anyopaque, frame: *Frame) Error!void,

            gains: *const fn (ptr: *anyopaque) Gains,
            setGains: *const fn (ptr: *anyopaque, gains_db: []const ?i8) Error!void,

            enable: *const fn (ptr: *anyopaque) Error!void,
            disable: *const fn (ptr: *anyopaque) Error!void,
        };

        pub fn init(ptr: *anyopaque, vtable: *const VTable) Self {
            return .{
                .ptr = ptr,
                .vtable = vtable,
            };
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

        pub fn read(self: Self, frame: *Frame) Error!void {
            return self.vtable.read(self.ptr, frame);
        }

        pub fn gains(self: Self) Gains {
            return self.vtable.gains(self.ptr);
        }

        pub fn setGains(self: Self, gains_db: []const ?i8) Error!void {
            return self.vtable.setGains(self.ptr, gains_db);
        }

        pub fn enable(self: Self) Error!void {
            return self.vtable.enable(self.ptr);
        }

        pub fn disable(self: Self) Error!void {
            return self.vtable.disable(self.ptr);
        }
    };
}
