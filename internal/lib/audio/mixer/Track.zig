//! audio.mixer.Track — track-facing mixer types and VTables.

const root = @This();
pub const Format = @import("Format.zig");
const glib = @import("glib");

pub const Config = struct {
    label: []const u8 = "",
    gain: f32 = 1.0,
    buffer_capacity: usize = 32000,
};

ptr: *anyopaque,
vtable: *const VTable,

pub const WriteError = anyerror;

pub const VTable = struct {
    write: *const fn (ptr: *anyopaque, format: Format, samples: []const i16) WriteError!void,
    deinit: *const fn (ptr: *anyopaque) void,
};

pub fn write(self: root, format: Format, samples: []const i16) WriteError!void {
    return self.vtable.write(self.ptr, format, samples);
}

/// `deinit()` must not race with active use of this handle or any copied value
/// derived from it. Callers must serialize teardown against in-flight writes.
pub fn deinit(self: root) void {
    self.vtable.deinit(self.ptr);
}

pub fn make(comptime lib: type, comptime Impl: type) type {
    comptime {
        if (!@hasDecl(Impl, "Config")) @compileError("Track impl must define Config");
        if (!@hasDecl(Impl, "init")) @compileError("Track impl must define init");
        if (!@hasDecl(Impl, "write")) @compileError("Track impl must define write");
        if (!@hasDecl(Impl, "deinit")) @compileError("Track impl must define deinit");
        if (!@hasField(Impl.Config, "allocator")) @compileError("Track impl Config must define allocator");

        _ = @as(*const fn (Impl.Config) anyerror!Impl, &Impl.init);
        _ = @as(*const fn (*Impl, Format, []const i16) WriteError!void, &Impl.write);
        _ = @as(*const fn (*Impl) void, &Impl.deinit);
    }

    const Allocator = lib.mem.Allocator;
    const Ctx = struct {
        allocator: Allocator,
        impl: Impl,

        pub fn write(self: *@This(), format: Format, samples: []const i16) WriteError!void {
            return self.impl.write(format, samples);
        }

        pub fn deinit(self: *@This()) void {
            self.impl.deinit();
            self.allocator.destroy(self);
        }
    };
    const VTableGen = struct {
        fn writeFn(ptr: *anyopaque, format: Format, samples: []const i16) WriteError!void {
            const self: *Ctx = @ptrCast(@alignCast(ptr));
            return self.write(format, samples);
        }

        fn deinitFn(ptr: *anyopaque) void {
            const self: *Ctx = @ptrCast(@alignCast(ptr));
            self.deinit();
        }

        const vtable = VTable{
            .write = writeFn,
            .deinit = deinitFn,
        };
    };

    return struct {
        pub const ImplConfig = Impl.Config;

        pub fn init(config: ImplConfig) !root {
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
                .vtable = &VTableGen.vtable,
            };
        }
    };
}

pub fn TestRunner(comptime lib: type) glib.testing.TestRunner {
    const TestCase = struct {
        const MakeImpl = struct {
            pub const Config = struct {
                allocator: lib.mem.Allocator,
                writes: *usize,
            };

            writes: *usize,

            pub fn init(config: @This().Config) !@This() {
                return .{
                    .writes = config.writes,
                };
            }

            pub fn write(self: *@This(), format: Format, samples: []const i16) WriteError!void {
                _ = format;
                self.writes.* += samples.len;
            }

            pub fn deinit(self: *@This()) void {
                _ = self;
            }
        };

        fn trackMakeSurface(testing: anytype) !void {
            comptime {
                _ = root.Format;
                _ = root.Config;
                _ = root.write;
                _ = root.deinit;
                _ = root.make;
                _ = make(lib, MakeImpl).init;
            }

            const TrackType = make(lib, MakeImpl);
            var writes: usize = 0;
            const made = try TrackType.init(.{
                .allocator = lib.testing.allocator,
                .writes = &writes,
            });
            defer made.deinit();
            try made.write(.{ .rate = 16000 }, &.{ 1, 2 });
            try testing.expectEqual(@as(usize, 2), writes);
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

            TestCase.trackMakeSurface(testing) catch |err| {
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
