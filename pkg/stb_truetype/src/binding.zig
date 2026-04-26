const glib = @import("glib");
const c = @cImport({
    @cInclude("stb_truetype.h");
});

pub const FontInfo = c.stbtt_fontinfo;

pub const stbtt_InitFont = c.stbtt_InitFont;
pub const stbtt_ScaleForPixelHeight = c.stbtt_ScaleForPixelHeight;
pub const stbtt_ScaleForMappingEmToPixels = c.stbtt_ScaleForMappingEmToPixels;
pub const stbtt_GetFontVMetrics = c.stbtt_GetFontVMetrics;
pub const stbtt_GetCodepointHMetrics = c.stbtt_GetCodepointHMetrics;
pub const stbtt_GetCodepointKernAdvance = c.stbtt_GetCodepointKernAdvance;
pub const stbtt_GetCodepointBitmapBox = c.stbtt_GetCodepointBitmapBox;
pub const stbtt_MakeCodepointBitmap = c.stbtt_MakeCodepointBitmap;
pub const stbtt_FindGlyphIndex = c.stbtt_FindGlyphIndex;

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            runExportsCoreStbSymbols() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: glib.std.mem.Allocator) void {
            _ = allocator;
            grt.std.testing.allocator.destroy(self);
        }

        fn runExportsCoreStbSymbols() !void {
            try grt.std.testing.expect(@sizeOf(FontInfo) > 0);

            _ = stbtt_InitFont;
            _ = stbtt_ScaleForPixelHeight;
            _ = stbtt_GetCodepointBitmapBox;
        }
    };

    const runner = grt.std.testing.allocator.create(Runner) catch @panic("OOM");
    runner.* = .{};
    return glib.testing.TestRunner.make(Runner).new(runner);
}
