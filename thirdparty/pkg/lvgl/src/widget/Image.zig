const glib = @import("glib");
const binding = @import("../binding.zig");
const Obj = @import("../object/Obj.zig");

const Self = @This();

handle: *binding.Obj,

pub const Descriptor = binding.ImageDsc;

pub fn fromRaw(handle: *binding.Obj) Self {
    return .{ .handle = handle };
}

pub fn fromObj(obj: Obj) Self {
    return fromRaw(obj.raw());
}

pub fn create(parent_obj: *const Obj) ?Self {
    const handle = binding.lv_image_create(parent_obj.raw()) orelse return null;
    return fromRaw(handle);
}

pub fn raw(self: *const Self) *binding.Obj {
    return self.handle;
}

pub fn asObj(self: *const Self) Obj {
    return Obj.fromRaw(self.handle);
}

pub fn setDescriptor(self: *const Self, descriptor: *const Descriptor) void {
    binding.lv_image_set_src(self.handle, @ptrCast(descriptor));
}

pub fn setScale(self: *const Self, zoom: u32) void {
    binding.lv_image_set_scale(self.handle, zoom);
}

pub fn source(self: *const Self) ?*const anyopaque {
    return binding.lv_image_get_src(self.handle);
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            const lvgl_testing = @import("../testing.zig");

            const Cases = struct {
                const pixels = [_]u8{
                    0xff, 0x00, 0x00, 0xff,
                    0x00, 0xff, 0x00, 0xff,
                    0x00, 0x00, 0xff, 0xff,
                    0xff, 0xff, 0xff, 0xff,
                };

                const descriptor: Descriptor = .{
                    .header = binding.imageHeader(binding.LV_COLOR_FORMAT_ARGB8888, 2, 2, 8, 0),
                    .data_size = pixels.len,
                    .data = &pixels,
                    .reserved = null,
                    .reserved_2 = null,
                };

                fn storesDescriptorSource() !void {
                    var fixture = try lvgl_testing.Fixture.init();
                    defer fixture.deinit();

                    var screen = fixture.screen();
                    var image = Self.create(&screen) orelse return error.OutOfMemory;
                    var obj = image.asObj();
                    defer obj.delete();

                    image.setDescriptor(&descriptor);

                    try grt.std.testing.expectEqual(@intFromPtr(&descriptor), @intFromPtr(image.source().?));
                }
            };

            Cases.storesDescriptorSource() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: glib.std.mem.Allocator) void {
            _ = allocator;
            grt.std.testing.allocator.destroy(self);
        }
    };

    const runner = grt.std.testing.allocator.create(Runner) catch @panic("OOM");
    runner.* = .{};
    return glib.testing.TestRunner.make(Runner).new(runner);
}
