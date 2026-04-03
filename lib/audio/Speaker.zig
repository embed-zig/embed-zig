//! audio.Speaker — type-erased speaker role surface.

const AudioSystem = @import("AudioSystem.zig");

pub const Error = AudioSystem.Error;

pub fn make(comptime lib: type, comptime samples_per_channel: usize) type {
    _ = lib;

    return struct {
        const Self = @This();

        pub const Frame = [samples_per_channel]i16;
        pub const frame_samples_per_channel: usize = samples_per_channel;

        ptr: *anyopaque,
        vtable: *const VTable,

        pub const VTable = struct {
            deinit: *const fn (ptr: *anyopaque) void,

            sampleRate: *const fn (ptr: *anyopaque) u32,

            write: *const fn (ptr: *anyopaque, frame: []const i16) Error!usize,

            gain: *const fn (ptr: *anyopaque) ?i8,
            setGain: *const fn (ptr: *anyopaque, gain_db: i8) Error!void,

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

        pub fn write(self: Self, frame: []const i16) Error!usize {
            return self.vtable.write(self.ptr, frame);
        }

        pub fn gain(self: Self) ?i8 {
            return self.vtable.gain(self.ptr);
        }

        pub fn setGain(self: Self, gain_db: i8) Error!void {
            return self.vtable.setGain(self.ptr, gain_db);
        }

        pub fn enable(self: Self) Error!void {
            return self.vtable.enable(self.ptr);
        }

        pub fn disable(self: Self) Error!void {
            return self.vtable.disable(self.ptr);
        }
    };
}
