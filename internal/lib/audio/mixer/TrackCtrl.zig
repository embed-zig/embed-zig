//! audio.mixer.TrackCtrl — track control VTable surface.

const root = @This();
const glib = @import("glib");

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    setGain: *const fn (ptr: *anyopaque, gain: f32) void,
    gain: *const fn (ptr: *anyopaque) f32,
    label: *const fn (ptr: *anyopaque) []const u8,
    readBytes: *const fn (ptr: *anyopaque) usize,
    setFadeOutDuration: *const fn (ptr: *anyopaque, ms: u32) void,
    closeWrite: *const fn (ptr: *anyopaque) void,
    closeWriteWithSilence: *const fn (ptr: *anyopaque, silence_ms: u32) void,
    close: *const fn (ptr: *anyopaque) void,
    closeWithError: *const fn (ptr: *anyopaque) void,
    setGainLinearTo: *const fn (ptr: *anyopaque, to: f32, duration_ms: u32) void,
    deinit: *const fn (ptr: *anyopaque) void,
};

pub fn setGain(self: root, value: f32) void {
    self.vtable.setGain(self.ptr, value);
}

pub fn gain(self: root) f32 {
    return self.vtable.gain(self.ptr);
}

pub fn label(self: root) []const u8 {
    return self.vtable.label(self.ptr);
}

pub fn readBytes(self: root) usize {
    return self.vtable.readBytes(self.ptr);
}

pub fn setFadeOutDuration(self: root, ms: u32) void {
    self.vtable.setFadeOutDuration(self.ptr, ms);
}

pub fn closeWrite(self: root) void {
    self.vtable.closeWrite(self.ptr);
}

pub fn closeWriteWithSilence(self: root, silence_ms: u32) void {
    self.vtable.closeWriteWithSilence(self.ptr, silence_ms);
}

pub fn close(self: root) void {
    self.vtable.close(self.ptr);
}

pub fn closeWithError(self: root) void {
    self.vtable.closeWithError(self.ptr);
}

pub fn setGainLinearTo(self: root, to: f32, duration_ms: u32) void {
    self.vtable.setGainLinearTo(self.ptr, to, duration_ms);
}

/// `deinit()` must not race with active use of this handle or any copied value
/// derived from it. Callers must serialize teardown against in-flight control
/// operations.
pub fn deinit(self: root) void {
    self.vtable.deinit(self.ptr);
}

pub fn make(comptime lib: type, comptime Impl: type) type {
    comptime {
        if (!@hasDecl(Impl, "Config")) @compileError("TrackCtrl impl must define Config");
        if (!@hasDecl(Impl, "init")) @compileError("TrackCtrl impl must define init");
        if (!@hasDecl(Impl, "setGain")) @compileError("TrackCtrl impl must define setGain");
        if (!@hasDecl(Impl, "label")) @compileError("TrackCtrl impl must define label");
        if (!@hasDecl(Impl, "readBytes")) @compileError("TrackCtrl impl must define readBytes");
        if (!@hasDecl(Impl, "closeWrite")) @compileError("TrackCtrl impl must define closeWrite");
        if (!@hasDecl(Impl, "closeWithError")) @compileError("TrackCtrl impl must define closeWithError");
        if (!@hasDecl(Impl, "deinit")) @compileError("TrackCtrl impl must define deinit");
        if (!@hasField(Impl.Config, "allocator")) @compileError("TrackCtrl impl Config must define allocator");

        _ = @as(*const fn (Impl.Config) anyerror!Impl, &Impl.init);
        _ = @as(*const fn (*Impl, f32) void, &Impl.setGain);
        _ = @as(*const fn (*Impl) []const u8, &Impl.label);
        _ = @as(*const fn (*Impl) usize, &Impl.readBytes);
        _ = @as(*const fn (*Impl) void, &Impl.closeWrite);
        _ = @as(*const fn (*Impl) void, &Impl.closeWithError);
        _ = @as(*const fn (*Impl) void, &Impl.deinit);
    }

    const Allocator = lib.mem.Allocator;
    const Ctx = struct {
        allocator: Allocator,
        impl: Impl,

        pub fn setGain(self: *@This(), value: f32) void {
            self.impl.setGain(value);
        }

        pub fn gain(self: *@This()) f32 {
            if (@hasDecl(Impl, "gain")) return self.impl.gain();
            return 1.0;
        }

        pub fn label(self: *@This()) []const u8 {
            return self.impl.label();
        }

        pub fn readBytes(self: *@This()) usize {
            return self.impl.readBytes();
        }

        pub fn setFadeOutDuration(self: *@This(), ms: u32) void {
            if (@hasDecl(Impl, "setFadeOutDuration")) self.impl.setFadeOutDuration(ms);
        }

        pub fn closeWrite(self: *@This()) void {
            self.impl.closeWrite();
        }

        pub fn closeWriteWithSilence(self: *@This(), silence_ms: u32) void {
            if (@hasDecl(Impl, "closeWriteWithSilence")) {
                self.impl.closeWriteWithSilence(silence_ms);
            } else {
                self.impl.closeWrite();
            }
        }

        pub fn close(self: *@This()) void {
            if (@hasDecl(Impl, "close")) {
                self.impl.close();
            } else {
                self.impl.closeWrite();
            }
        }

        pub fn closeWithError(self: *@This()) void {
            self.impl.closeWithError();
        }

        pub fn setGainLinearTo(self: *@This(), to: f32, duration_ms: u32) void {
            if (@hasDecl(Impl, "setGainLinearTo")) {
                self.impl.setGainLinearTo(to, duration_ms);
            } else {
                self.impl.setGain(to);
            }
        }

        pub fn deinit(self: *@This()) void {
            self.impl.deinit();
            self.allocator.destroy(self);
        }
    };
    const Gen = struct {
        fn setGainFn(ptr: *anyopaque, value: f32) void {
            const self: *Ctx = @ptrCast(@alignCast(ptr));
            self.setGain(value);
        }

        fn gainFn(ptr: *anyopaque) f32 {
            const self: *Ctx = @ptrCast(@alignCast(ptr));
            return self.gain();
        }

        fn labelFn(ptr: *anyopaque) []const u8 {
            const self: *Ctx = @ptrCast(@alignCast(ptr));
            return self.label();
        }

        fn readBytesFn(ptr: *anyopaque) usize {
            const self: *Ctx = @ptrCast(@alignCast(ptr));
            return self.readBytes();
        }

        fn setFadeOutDurationFn(ptr: *anyopaque, ms: u32) void {
            const self: *Ctx = @ptrCast(@alignCast(ptr));
            self.setFadeOutDuration(ms);
        }

        fn closeWriteFn(ptr: *anyopaque) void {
            const self: *Ctx = @ptrCast(@alignCast(ptr));
            self.closeWrite();
        }

        fn closeWriteWithSilenceFn(ptr: *anyopaque, silence_ms: u32) void {
            const self: *Ctx = @ptrCast(@alignCast(ptr));
            self.closeWriteWithSilence(silence_ms);
        }

        fn closeFn(ptr: *anyopaque) void {
            const self: *Ctx = @ptrCast(@alignCast(ptr));
            self.close();
        }

        fn closeWithErrorFn(ptr: *anyopaque) void {
            const self: *Ctx = @ptrCast(@alignCast(ptr));
            self.closeWithError();
        }

        fn setGainLinearToFn(ptr: *anyopaque, to: f32, duration_ms: u32) void {
            const self: *Ctx = @ptrCast(@alignCast(ptr));
            self.setGainLinearTo(to, duration_ms);
        }

        fn deinitFn(ptr: *anyopaque) void {
            const self: *Ctx = @ptrCast(@alignCast(ptr));
            self.deinit();
        }

        const vtable = VTable{
            .setGain = setGainFn,
            .gain = gainFn,
            .label = labelFn,
            .readBytes = readBytesFn,
            .setFadeOutDuration = setFadeOutDurationFn,
            .closeWrite = closeWriteFn,
            .closeWriteWithSilence = closeWriteWithSilenceFn,
            .close = closeFn,
            .closeWithError = closeWithErrorFn,
            .setGainLinearTo = setGainLinearToFn,
            .deinit = deinitFn,
        };
    };

    return struct {
        pub const Config = Impl.Config;

        pub fn init(config: Config) !root {
            var impl = try Impl.init(config);
            errdefer impl.deinit();

            const storage = try config.allocator.create(Ctx);
            errdefer config.allocator.destroy(storage);
            storage.* = .{
                .allocator = config.allocator,
                .impl = impl,
            };
            return .{
                .ptr = storage,
                .vtable = &Gen.vtable,
            };
        }
    };
}

pub fn TestRunner(comptime lib: type) glib.testing.TestRunner {
    const TestCase = struct {
        const State = struct {
            current_gain: f32 = 1.0,
            current_label: []const u8 = "made",
            bytes: usize = 11,
        };

        const MakeImpl = struct {
            pub const Config = struct {
                allocator: lib.mem.Allocator,
                state: *State,
            };

            state: *State,

            pub fn init(config: Config) !@This() {
                return .{
                    .state = config.state,
                };
            }

            pub fn setGain(self: *@This(), value: f32) void {
                self.state.current_gain = value;
            }

            pub fn gain(self: *@This()) f32 {
                return self.state.current_gain;
            }

            pub fn label(self: *@This()) []const u8 {
                return self.state.current_label;
            }

            pub fn readBytes(self: *@This()) usize {
                return self.state.bytes;
            }

            pub fn closeWrite(_: *@This()) void {}
            pub fn closeWithError(_: *@This()) void {}
            pub fn deinit(_: *@This()) void {}
        };

        fn trackCtrlMakeSurface(testing: anytype) !void {
            comptime {
                _ = root.setGain;
                _ = root.gain;
                _ = root.label;
                _ = root.readBytes;
                _ = root.closeWrite;
                _ = root.close;
                _ = root.closeWithError;
                _ = root.deinit;
                _ = root.make;
                _ = make(lib, MakeImpl).init;
            }

            const TrackCtrlType = make(lib, MakeImpl);
            var state = State{};
            const made = try TrackCtrlType.init(.{
                .allocator = lib.testing.allocator,
                .state = &state,
            });
            defer made.deinit();
            made.setGain(0.5);
            try testing.expectEqual(@as(f32, 0.5), made.gain());
            try testing.expectEqualStrings("made", made.label());
            try testing.expectEqual(@as(usize, 11), made.readBytes());
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;
            const testing = lib.testing;

            TestCase.trackCtrlMakeSurface(testing) catch |err| {
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
    return glib.testing.TestRunner.make(Runner).new(&Holder.runner);
}
