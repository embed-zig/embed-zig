const c = @cImport({
    @cInclude("portaudio.h");
});

pub const PaError = c.PaError;
pub const PaErrorCode = c.PaErrorCode;
pub const PaHostApiIndex = c.PaHostApiIndex;
pub const PaHostApiTypeId = c.PaHostApiTypeId;
pub const PaDeviceIndex = c.PaDeviceIndex;
pub const PaSampleFormat = c.PaSampleFormat;
pub const PaStreamFlags = c.PaStreamFlags;
pub const PaTime = c.PaTime;
pub const PaStream = c.PaStream;
pub const PaVersionInfo = c.PaVersionInfo;
pub const PaHostApiInfo = c.PaHostApiInfo;
pub const PaDeviceInfo = c.PaDeviceInfo;
pub const PaStreamParameters = c.PaStreamParameters;
pub const PaStreamInfo = c.PaStreamInfo;

pub const paNoError = c.paNoError;
pub const paFormatIsSupported = c.paFormatIsSupported;
pub const paNoDevice = c.paNoDevice;
pub const paUseHostApiSpecificDeviceSpecification = c.paUseHostApiSpecificDeviceSpecification;
pub const paFramesPerBufferUnspecified = c.paFramesPerBufferUnspecified;

pub const paFloat32 = c.paFloat32;
pub const paInt32 = c.paInt32;
pub const paInt24 = c.paInt24;
pub const paInt16 = c.paInt16;
pub const paInt8 = c.paInt8;
pub const paUInt8 = c.paUInt8;
pub const paCustomFormat = c.paCustomFormat;
pub const paNonInterleaved = c.paNonInterleaved;

pub const paNoFlag = c.paNoFlag;
pub const paClipOff = c.paClipOff;
pub const paDitherOff = c.paDitherOff;
pub const paNeverDropInput = c.paNeverDropInput;
pub const paPrimeOutputBuffersUsingStreamCallback = c.paPrimeOutputBuffersUsingStreamCallback;
pub const paPlatformSpecificFlags = c.paPlatformSpecificFlags;

pub const paNotInitialized = c.paNotInitialized;
pub const paInvalidChannelCount = c.paInvalidChannelCount;
pub const paInvalidSampleRate = c.paInvalidSampleRate;
pub const paInvalidDevice = c.paInvalidDevice;
pub const paInvalidFlag = c.paInvalidFlag;
pub const paSampleFormatNotSupported = c.paSampleFormatNotSupported;
pub const paBadIODeviceCombination = c.paBadIODeviceCombination;
pub const paInsufficientMemory = c.paInsufficientMemory;
pub const paBufferTooBig = c.paBufferTooBig;
pub const paBufferTooSmall = c.paBufferTooSmall;
pub const paNullCallback = c.paNullCallback;
pub const paBadStreamPtr = c.paBadStreamPtr;
pub const paTimedOut = c.paTimedOut;
pub const paInternalError = c.paInternalError;
pub const paDeviceUnavailable = c.paDeviceUnavailable;
pub const paIncompatibleHostApiSpecificStreamInfo = c.paIncompatibleHostApiSpecificStreamInfo;
pub const paStreamIsStopped = c.paStreamIsStopped;
pub const paStreamIsNotStopped = c.paStreamIsNotStopped;
pub const paInputOverflowed = c.paInputOverflowed;
pub const paOutputUnderflowed = c.paOutputUnderflowed;
pub const paHostApiNotFound = c.paHostApiNotFound;
pub const paInvalidHostApi = c.paInvalidHostApi;
pub const paCanNotReadFromACallbackStream = c.paCanNotReadFromACallbackStream;
pub const paCanNotWriteToACallbackStream = c.paCanNotWriteToACallbackStream;
pub const paCanNotReadFromAnOutputOnlyStream = c.paCanNotReadFromAnOutputOnlyStream;
pub const paCanNotWriteToAnInputOnlyStream = c.paCanNotWriteToAnInputOnlyStream;
pub const paIncompatibleStreamHostApi = c.paIncompatibleStreamHostApi;
pub const paBadBufferPtr = c.paBadBufferPtr;
pub const paUnanticipatedHostError = c.paUnanticipatedHostError;

pub const Pa_GetVersion = c.Pa_GetVersion;
pub const Pa_GetVersionText = c.Pa_GetVersionText;
pub const Pa_GetErrorText = c.Pa_GetErrorText;
pub const Pa_Initialize = c.Pa_Initialize;
pub const Pa_Terminate = c.Pa_Terminate;
pub const Pa_GetHostApiCount = c.Pa_GetHostApiCount;
pub const Pa_GetDefaultHostApi = c.Pa_GetDefaultHostApi;
pub const Pa_GetHostApiInfo = c.Pa_GetHostApiInfo;
pub const Pa_GetDeviceCount = c.Pa_GetDeviceCount;
pub const Pa_GetDefaultInputDevice = c.Pa_GetDefaultInputDevice;
pub const Pa_GetDefaultOutputDevice = c.Pa_GetDefaultOutputDevice;
pub const Pa_GetDeviceInfo = c.Pa_GetDeviceInfo;
pub const Pa_IsFormatSupported = c.Pa_IsFormatSupported;
pub const Pa_OpenStream = c.Pa_OpenStream;
pub const Pa_OpenDefaultStream = c.Pa_OpenDefaultStream;
pub const Pa_CloseStream = c.Pa_CloseStream;
pub const Pa_StartStream = c.Pa_StartStream;
pub const Pa_StopStream = c.Pa_StopStream;
pub const Pa_AbortStream = c.Pa_AbortStream;
pub const Pa_IsStreamStopped = c.Pa_IsStreamStopped;
pub const Pa_IsStreamActive = c.Pa_IsStreamActive;
pub const Pa_GetStreamInfo = c.Pa_GetStreamInfo;
pub const Pa_ReadStream = c.Pa_ReadStream;
pub const Pa_WriteStream = c.Pa_WriteStream;
pub const Pa_GetStreamReadAvailable = c.Pa_GetStreamReadAvailable;
pub const Pa_GetStreamWriteAvailable = c.Pa_GetStreamWriteAvailable;

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

            exportsCorePortaudioSymbols(lib) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: lib.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }

        fn exportsCorePortaudioSymbols(comptime L: type) !void {
            const testing = L.testing;

            try testing.expect(@sizeOf(PaDeviceInfo) > 0);
            try testing.expect(@sizeOf(PaStreamParameters) > 0);
            try testing.expect(@sizeOf(PaStreamInfo) > 0);

            _ = Pa_Initialize;
            _ = Pa_OpenStream;
            _ = Pa_ReadStream;
            _ = Pa_WriteStream;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}
