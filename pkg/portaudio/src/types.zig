const binding = @import("binding.zig");

pub const DeviceIndex = binding.PaDeviceIndex;
pub const HostApiIndex = binding.PaHostApiIndex;
pub const Time = binding.PaTime;
pub const StreamFlags = binding.PaStreamFlags;

pub const no_device: DeviceIndex = binding.paNoDevice;
pub const use_host_api_specific_device_specification: DeviceIndex = binding.paUseHostApiSpecificDeviceSpecification;
pub const frames_per_buffer_unspecified: c_ulong = binding.paFramesPerBufferUnspecified;
pub const format_is_supported: c_int = binding.paFormatIsSupported;
pub const non_interleaved_flag: binding.PaSampleFormat = binding.paNonInterleaved;

pub const SampleFormat = enum(c_ulong) {
    float32 = binding.paFloat32,
    int32 = binding.paInt32,
    int24 = binding.paInt24,
    int16 = binding.paInt16,
    int8 = binding.paInt8,
    uint8 = binding.paUInt8,
    custom = binding.paCustomFormat,
};

pub fn toPaSampleFormat(format: SampleFormat) binding.PaSampleFormat {
    return @intFromEnum(format);
}

pub fn toPaNonInterleavedSampleFormat(format: SampleFormat) binding.PaSampleFormat {
    return toPaSampleFormat(format) | non_interleaved_flag;
}

pub fn TestRunner(comptime lib: type) @import("testing").TestRunner {
    const testing_api = @import("testing");

    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            sampleFormatMapsToPortaudioConstants(lib) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            deviceSpecialValuesMatchBinding(lib) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: lib.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }

        fn sampleFormatMapsToPortaudioConstants(comptime L: type) !void {
            const testing = L.testing;

            try testing.expectEqual(binding.paFloat32, toPaSampleFormat(.float32));
            try testing.expectEqual(binding.paInt16, toPaSampleFormat(.int16));
            try testing.expectEqual(binding.paInt16 | binding.paNonInterleaved, toPaNonInterleavedSampleFormat(.int16));
        }

        fn deviceSpecialValuesMatchBinding(comptime L: type) !void {
            const testing = L.testing;

            try testing.expectEqual(binding.paNoDevice, no_device);
            try testing.expectEqual(binding.paUseHostApiSpecificDeviceSpecification, use_host_api_specific_device_specification);
            try testing.expectEqual(binding.paFramesPerBufferUnspecified, frames_per_buffer_unspecified);
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}
