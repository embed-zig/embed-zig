const glib = @import("glib");
const binding = @import("binding.zig");

const Self = @This();

handle: *const binding.Font,
mutable_handle: ?*binding.Font = null,
owns_tiny_ttf: bool = false,

pub const Kerning = binding.FontKerning;
pub const kerning_normal: Kerning = binding.LV_FONT_KERNING_NORMAL;
pub const kerning_none: Kerning = binding.LV_FONT_KERNING_NONE;

pub fn fromRaw(handle: *binding.Font) Self {
    return .{
        .handle = handle,
        .mutable_handle = handle,
    };
}

pub fn fromRawConst(handle: *const binding.Font) Self {
    return .{ .handle = handle };
}

pub fn default() ?Self {
    const handle = binding.lv_font_get_default() orelse return null;
    return fromRawConst(handle);
}

pub fn createTtfFile(path: [:0]const u8, size: i32) ?Self {
    const handle = binding.lv_tiny_ttf_create_file(path.ptr, size) orelse return null;
    return fromOwnedTinyTtf(handle);
}

pub fn createTtfFileEx(path: [:0]const u8, size: i32, kerning: Kerning, cache_size: usize) ?Self {
    const handle = binding.lv_tiny_ttf_create_file_ex(path.ptr, size, kerning, cache_size) orelse return null;
    return fromOwnedTinyTtf(handle);
}

/// `data` is stored by reference by LVGL; keep it valid until `destroy()`.
pub fn createTtfData(data: []const u8, size: i32) ?Self {
    const handle = binding.lv_tiny_ttf_create_data(data.ptr, data.len, size) orelse return null;
    return fromOwnedTinyTtf(handle);
}

/// `data` is stored by reference by LVGL; keep it valid until `destroy()`.
pub fn createTtfDataEx(data: []const u8, size: i32, kerning: Kerning, cache_size: usize) ?Self {
    const handle = binding.lv_tiny_ttf_create_data_ex(data.ptr, data.len, size, kerning, cache_size) orelse return null;
    return fromOwnedTinyTtf(handle);
}

pub fn destroy(self: *Self) void {
    if (self.owns_tiny_ttf) {
        binding.lv_tiny_ttf_destroy(self.rawMutablePtr());
    }
    self.* = undefined;
}

pub fn setSize(self: *const Self, size: i32) void {
    binding.lv_tiny_ttf_set_size(self.rawMutablePtr(), size);
}

pub fn setKerning(self: *const Self, kerning: Kerning) void {
    binding.lv_font_set_kerning(self.rawMutablePtr(), kerning);
}

pub fn lineHeight(self: *const Self) i32 {
    return binding.lv_font_get_line_height(self.rawConstPtr());
}

pub fn glyphWidth(self: *const Self, letter: u32, letter_next: u32) u16 {
    return binding.lv_font_get_glyph_width(self.rawConstPtr(), letter, letter_next);
}

pub fn raw(self: *const Self) *binding.Font {
    return self.rawMutablePtr();
}

pub fn rawConstPtr(self: *const Self) *const binding.Font {
    return self.handle;
}

pub fn isMutable(self: *const Self) bool {
    return self.mutable_handle != null;
}

fn fromOwnedTinyTtf(handle: *binding.Font) Self {
    return .{
        .handle = handle,
        .mutable_handle = handle,
        .owns_tiny_ttf = true,
    };
}

fn rawMutablePtr(self: *const Self) *binding.Font {
    return self.mutable_handle orelse @panic("lvgl.Font is borrowed and cannot be mutated");
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

            const Cases = struct {
                fn defaultFontExposesReadOnlyMetrics() !void {
                    binding.lv_init();
                    defer binding.lv_deinit();

                    const font = Self.default() orelse return error.ExpectedDefaultFont;

                    try grt.std.testing.expect(!font.isMutable());
                    try grt.std.testing.expect(font.lineHeight() > 0);
                    try grt.std.testing.expect(font.glyphWidth('A', 'V') > 0);
                }
            };

            Cases.defaultFontExposesReadOnlyMetrics() catch |err| {
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
