const glib = @import("glib");
const ledstrip = @import("ledstrip");

pub const Allocator = glib.std.mem.Allocator;

pub const OwnedPixels = struct {
    pub const Color = ledstrip.Color;

    allocator: Allocator,
    items: []Color,

    pub fn init(allocator: Allocator, source: []const Color) !OwnedPixels {
        return .{
            .allocator = allocator,
            .items = try allocator.dupe(Color, source),
        };
    }

    pub fn fromFrame(allocator: Allocator, frame: anytype) !OwnedPixels {
        const Frame = @TypeOf(frame);
        comptime {
            if (!@hasField(Frame, "pixels")) {
                @compileError("zux.ledstrip.event.OwnedPixels.fromFrame requires a frame with pixels field");
            }
            const pixels_info = @typeInfo(@FieldType(Frame, "pixels"));
            if (pixels_info != .array) {
                @compileError("zux.ledstrip.event.OwnedPixels.fromFrame requires frame.pixels to be an array");
            }
        }

        return try init(allocator, frame.pixels[0..]);
    }

    pub fn deinit(self: OwnedPixels) void {
        self.allocator.free(self.items);
    }

    pub fn slice(self: *const OwnedPixels) []const Color {
        return self.items;
    }
};

pub const Set = struct {
    pub const kind = .ledstrip_set;

    source_id: u32,
    pixels: OwnedPixels,
    brightness: u8 = 255,
    duration: u32 = 0,
};

pub const SetPixels = struct {
    pub const kind = .ledstrip_set_pixels;

    source_id: u32,
    pixels: OwnedPixels,
    brightness: u8 = 255,
};

pub const Flash = struct {
    pub const kind = .ledstrip_flash;

    source_id: u32,
    pixels: OwnedPixels,
    brightness: u8 = 255,
    duration: glib.time.duration.Duration,
    interval: glib.time.duration.Duration,
};

pub const Pingpong = struct {
    pub const kind = .ledstrip_pingpong;

    source_id: u32,
    from_pixels: OwnedPixels,
    to_pixels: OwnedPixels,
    brightness: u8 = 255,
    duration: glib.time.duration.Duration,
    interval: glib.time.duration.Duration,
};

pub const Rotate = struct {
    pub const kind = .ledstrip_rotate;

    source_id: u32,
    pixels: OwnedPixels,
    brightness: u8 = 255,
    duration: glib.time.duration.Duration,
    interval: glib.time.duration.Duration,
};
