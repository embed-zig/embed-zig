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

pub fn TestRunner(comptime lib: type) @import("testing").TestRunner {
    const embed = @import("embed");
    const testing_api = @import("testing");

    const Runner = struct {
        const testing = lib.testing;

        pub fn init(self: *@This(), allocator: embed.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: embed.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            runExportsCoreStbSymbols() catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: embed.mem.Allocator) void {
            _ = allocator;
            lib.testing.allocator.destroy(self);
        }

        fn runExportsCoreStbSymbols() !void {
            try testing.expect(@sizeOf(FontInfo) > 0);

            _ = stbtt_InitFont;
            _ = stbtt_ScaleForPixelHeight;
            _ = stbtt_GetCodepointBitmapBox;
        }
    };

    const runner = lib.testing.allocator.create(Runner) catch @panic("OOM");
    runner.* = .{};
    return testing_api.TestRunner.make(Runner).new(runner);
}
