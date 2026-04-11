//! Adc — non-owning type-erased voltage reader.

const Adc = @This();
const testing_api = @import("testing");

ptr: *anyopaque,
vtable: *const VTable,

pub const Error = error{
    Timeout,
    HwError,
    Unexpected,
};

pub const VTable = struct {
    readVoltage: *const fn (ptr: *anyopaque) Error!f32,
};

pub fn readVoltage(self: Adc) Error!f32 {
    return self.vtable.readVoltage(self.ptr);
}

pub fn init(pointer: anytype) Adc {
    const Ptr = @TypeOf(pointer);
    const info = @typeInfo(Ptr);
    if (info != .pointer or info.pointer.size != .one)
        @compileError("Adc.init expects a single-item pointer");

    const Impl = info.pointer.child;

    const gen = struct {
        fn readVoltageFn(ptr: *anyopaque) Error!f32 {
            const self: *Impl = @ptrCast(@alignCast(ptr));
            return self.readVoltage();
        }

        const vtable = VTable{
            .readVoltage = readVoltageFn,
        };
    };

    return .{
        .ptr = pointer,
        .vtable = &gen.vtable,
    };
}

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    const TestCase = struct {
        fn dispatchesReadVoltage() !void {
            const Fake = struct {
                voltage: f32 = 1.23,

                fn readVoltage(self: *@This()) Error!f32 {
                    return self.voltage;
                }
            };

            var fake = Fake{};
            const adc = Adc.init(&fake);
            try lib.testing.expectEqual(@as(f32, 1.23), try adc.readVoltage());
        }

        fn propagatesBackendErrors() !void {
            const Fake = struct {
                fail: bool = false,

                fn readVoltage(self: *@This()) Error!f32 {
                    if (self.fail) return error.Timeout;
                    return 0.5;
                }
            };

            var fake = Fake{ .fail = true };
            const adc = Adc.init(&fake);
            try lib.testing.expectError(error.Timeout, adc.readVoltage());
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

            TestCase.dispatchesReadVoltage() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.propagatesBackendErrors() catch |err| {
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
