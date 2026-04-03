//! audio.Mixer — type-erased PCM mixer surface.

const root = @This();
const TrackMod = @import("mixer/Track.zig");
const TrackCtrlMod = @import("mixer/TrackCtrl.zig");

pub const Format = TrackMod.Format;
pub const Track = TrackMod;
pub const TrackCtrl = TrackCtrlMod;

/// `TrackHandle` returns two views over one logical track. Callers must
/// eventually `deinit()` both `track` and `ctrl` exactly once, and must not use
/// either view after its own `deinit()` or after the mixer that created it has
/// been torn down. Teardown of either side must also be serialized against
/// in-flight reads, writes, control calls, and mixer lifecycle operations.
pub const TrackHandle = struct {
    track: Track,
    ctrl: TrackCtrl,
};

pub const CreateTrackError = anyerror;

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    deinit: *const fn (ptr: *anyopaque) void,
    createTrack: *const fn (ptr: *anyopaque, config: Track.Config) CreateTrackError!TrackHandle,
    read: *const fn (ptr: *anyopaque, out: []i16) ?usize,
    closeWrite: *const fn (ptr: *anyopaque) void,
    close: *const fn (ptr: *anyopaque) void,
    closeWithError: *const fn (ptr: *anyopaque) void,
};

/// `deinit()` must not race with active use of this handle or any copied value
/// derived from it. Callers must serialize teardown against in-flight reads,
/// writes, and control operations on handles created from this mixer.
pub fn deinit(self: root) void {
    self.vtable.deinit(self.ptr);
}

pub fn createTrack(self: root, config: Track.Config) CreateTrackError!TrackHandle {
    return self.vtable.createTrack(self.ptr, config);
}

pub fn read(self: root, out: []i16) ?usize {
    return self.vtable.read(self.ptr, out);
}

pub fn closeWrite(self: root) void {
    self.vtable.closeWrite(self.ptr);
}

pub fn close(self: root) void {
    self.vtable.close(self.ptr);
}

pub fn closeWithError(self: root) void {
    self.vtable.closeWithError(self.ptr);
}

pub fn DefaultImpl(comptime lib: type) type {
    return @import("mixer/Default.zig").make(lib, TrackHandle);
}

pub fn makeDefault(comptime lib: type) type {
    return make(lib, DefaultImpl(lib));
}

pub fn make(comptime lib: type, comptime Impl: type) type {
    comptime {
        if (!@hasDecl(Impl, "Config")) @compileError("Mixer impl must define Config");
        if (!@hasDecl(Impl, "init")) @compileError("Mixer impl must define init");
        if (!@hasDecl(Impl, "createTrack")) @compileError("Mixer impl must define createTrack");
        if (!@hasDecl(Impl, "read")) @compileError("Mixer impl must define read");
        if (!@hasDecl(Impl, "closeWrite")) @compileError("Mixer impl must define closeWrite");
        if (!@hasDecl(Impl, "close")) @compileError("Mixer impl must define close");
        if (!@hasDecl(Impl, "closeWithError")) @compileError("Mixer impl must define closeWithError");
        if (!@hasDecl(Impl, "deinit")) @compileError("Mixer impl must define deinit");
        if (!@hasField(Impl.Config, "allocator")) @compileError("Mixer impl Config must define allocator");

        _ = @as(*const fn (Impl.Config) anyerror!Impl, &Impl.init);
        _ = @as(*const fn (*Impl, Track.Config) CreateTrackError!TrackHandle, &Impl.createTrack);
        _ = @as(*const fn (*Impl, []i16) ?usize, &Impl.read);
        _ = @as(*const fn (*Impl) void, &Impl.closeWrite);
        _ = @as(*const fn (*Impl) void, &Impl.close);
        _ = @as(*const fn (*Impl) void, &Impl.closeWithError);
        _ = @as(*const fn (*Impl) void, &Impl.deinit);
    }

    const Allocator = lib.mem.Allocator;
    const Ctx = struct {
        allocator: Allocator,
        impl: Impl,

        pub fn deinit(self: *@This()) void {
            self.impl.deinit();
            self.allocator.destroy(self);
        }

        pub fn createTrack(self: *@This(), config: Track.Config) CreateTrackError!TrackHandle {
            return self.impl.createTrack(config);
        }

        pub fn read(self: *@This(), out: []i16) ?usize {
            return self.impl.read(out);
        }

        pub fn closeWrite(self: *@This()) void {
            self.impl.closeWrite();
        }

        pub fn close(self: *@This()) void {
            self.impl.close();
        }

        pub fn closeWithError(self: *@This()) void {
            self.impl.closeWithError();
        }
    };
    const Gen = struct {
        fn deinitFn(ptr: *anyopaque) void {
            const self: *Ctx = @ptrCast(@alignCast(ptr));
            self.deinit();
        }

        fn createTrackFn(ptr: *anyopaque, config: Track.Config) CreateTrackError!TrackHandle {
            const self: *Ctx = @ptrCast(@alignCast(ptr));
            return self.createTrack(config);
        }

        fn readFn(ptr: *anyopaque, out: []i16) ?usize {
            const self: *Ctx = @ptrCast(@alignCast(ptr));
            return self.read(out);
        }

        fn closeWriteFn(ptr: *anyopaque) void {
            const self: *Ctx = @ptrCast(@alignCast(ptr));
            self.closeWrite();
        }

        fn closeFn(ptr: *anyopaque) void {
            const self: *Ctx = @ptrCast(@alignCast(ptr));
            self.close();
        }

        fn closeWithErrorFn(ptr: *anyopaque) void {
            const self: *Ctx = @ptrCast(@alignCast(ptr));
            self.closeWithError();
        }

        const vtable = VTable{
            .deinit = deinitFn,
            .createTrack = createTrackFn,
            .read = readFn,
            .closeWrite = closeWriteFn,
            .close = closeFn,
            .closeWithError = closeWithErrorFn,
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

test "audio/unit_tests/Mixer_exposes_vtable_surface" {
    const std = @import("std");

    const TrackImpl = struct {
        pub const Config = struct {
            allocator: std.mem.Allocator,
            writes: *usize,
        };

        writes: *usize,

        pub fn init(config: Config) !@This() {
            return .{
                .writes = config.writes,
            };
        }

        pub fn write(self: *@This(), format: Track.Format, samples: []const i16) anyerror!void {
            _ = format;
            self.writes.* += samples.len;
        }

        pub fn deinit(self: *@This()) void {
            _ = self;
        }
    };

    const TrackCtrlState = struct {
        current_gain: f32 = 1.0,
        current_label: []const u8 = "track",
        bytes_read: usize = 12,
        closed: bool = false,
        errored: bool = false,
    };

    const TrackCtrlImpl = struct {
        pub const Config = struct {
            allocator: std.mem.Allocator,
            state: *TrackCtrlState,
        };

        state: *TrackCtrlState,

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
            return self.state.bytes_read;
        }

        pub fn setFadeOutDuration(_: *@This(), _: u32) void {}

        pub fn closeWrite(self: *@This()) void {
            self.state.closed = true;
        }

        pub fn closeWriteWithSilence(self: *@This(), _: u32) void {
            self.state.closed = true;
        }

        pub fn close(self: *@This()) void {
            self.state.closed = true;
        }

        pub fn closeWithError(self: *@This()) void {
            self.state.closed = true;
            self.state.errored = true;
        }

        pub fn setGainLinearTo(self: *@This(), to: f32, _: u32) void {
            self.state.current_gain = to;
        }

        pub fn deinit(self: *@This()) void {
            _ = self;
        }
    };

    const Impl = struct {
        pub const Config = struct {
            allocator: std.mem.Allocator,
        };

        allocator: std.mem.Allocator,
        track_writes: usize = 0,
        ctrl_state: TrackCtrlState = .{},
        closed: bool = false,
        close_err: bool = false,

        pub fn init(config: Config) !@This() {
            return .{
                .allocator = config.allocator,
            };
        }

        pub fn createTrack(self: *@This(), _: Track.Config) CreateTrackError!TrackHandle {
            const TrackType = Track.make(std, TrackImpl);
            const TrackCtrlType = TrackCtrl.make(std, TrackCtrlImpl);
            return .{
                .track = try TrackType.init(.{
                    .allocator = self.allocator,
                    .writes = &self.track_writes,
                }),
                .ctrl = try TrackCtrlType.init(.{
                    .allocator = self.allocator,
                    .state = &self.ctrl_state,
                }),
            };
        }

        pub fn read(_: *@This(), out: []i16) ?usize {
            if (out.len >= 2) {
                out[0] = 1;
                out[1] = 2;
                return 2;
            }
            return out.len;
        }

        pub fn closeWrite(self: *@This()) void {
            self.closed = true;
        }

        pub fn close(self: *@This()) void {
            self.closed = true;
        }

        pub fn closeWithError(self: *@This()) void {
            self.closed = true;
            self.close_err = true;
        }

        pub fn deinit(self: *@This()) void {
            _ = self;
        }
    };

    comptime {
        _ = root.DefaultImpl;
        _ = root.makeDefault;
        _ = root.Format;
        _ = root.Track;
        _ = root.TrackCtrl;
        _ = root.TrackHandle;
        _ = root.deinit;
        _ = root.createTrack;
        _ = root.read;
        _ = root.closeWrite;
        _ = root.close;
        _ = root.closeWithError;
        _ = root.make;
        _ = Track.write;
        _ = Track.deinit;
        _ = Track.make;
        _ = TrackCtrl.setGain;
        _ = TrackCtrl.gain;
        _ = TrackCtrl.label;
        _ = TrackCtrl.readBytes;
        _ = TrackCtrl.closeWrite;
        _ = TrackCtrl.close;
        _ = TrackCtrl.closeWithError;
        _ = TrackCtrl.deinit;
        _ = TrackCtrl.make;
        _ = make(std, Impl).init;
        if (!@hasField(make(std, Impl).Config, "allocator")) {
            @compileError("make config must expose allocator");
        }
    }

    const MixerType = make(std, Impl);
    const mixer = try MixerType.init(.{
        .allocator = std.testing.allocator,
    });
    defer mixer.deinit();

    const handle = try mixer.createTrack(.{ .label = "song" });
    defer handle.track.deinit();
    defer handle.ctrl.deinit();
    try handle.track.write(.{ .rate = 16000 }, &.{ 1, 2, 3, 4 });
    try std.testing.expectEqual(@as(f32, 1.0), handle.ctrl.gain());
    handle.ctrl.setGain(0.5);
    try std.testing.expectEqual(@as(f32, 0.5), handle.ctrl.gain());
    try std.testing.expectEqualStrings("track", handle.ctrl.label());
    try std.testing.expectEqual(@as(usize, 12), handle.ctrl.readBytes());

    var out: [4]i16 = undefined;
    const read_n = mixer.read(&out) orelse 0;
    try std.testing.expectEqual(@as(usize, 2), read_n);
    try std.testing.expectEqual(@as(i16, 1), out[0]);
    try std.testing.expectEqual(@as(i16, 2), out[1]);
}
