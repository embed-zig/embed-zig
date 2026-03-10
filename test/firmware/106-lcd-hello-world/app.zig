//! 106-lcd-hello-world — Display "Hello World!" on an LCD.
//!
//! Renders anti-aliased text via stb_truetype onto a heap-allocated
//! framebuffer and flushes the entire buffer to the display.

const embed = @import("embed");
const hal_display = embed.hal.display;
const ui = embed.pkg.ui.render;
const board_spec = @import("board_spec.zig");

const SCREEN_W: u16 = 320;
const SCREEN_H: u16 = 240;
const TEXT_FONT_SIZE: f32 = 24.0;
const ICON_FONT_SIZE: f32 = 44.0;
const TEXT_FONT_PATH = "/assets/fonts/text.ttf";
const ICON_FONT_PATH = "/assets/fonts/icon.ttf";

const FB = ui.Framebuffer(SCREEN_W, SCREEN_H, .rgb565);

const embedded_text_ttf_data = @embedFile("data/fonts/text.ttf");
const embedded_icon_ttf_data = @embedFile("data/fonts/icon.ttf");

const ICON_SQUARES_FOUR = "\xee\x91\xa4"; // U+E464

const BLACK = hal_display.rgb565(0, 0, 0);
const WHITE = hal_display.rgb565(255, 255, 255);
const ACCENT = hal_display.rgb565(255, 176, 0);
const TITLE_EN = "Hello World!";
const TITLE_ZH = "你好 世界";

fn loadFontData(comptime FsType: type, alloc: anytype, path: []const u8) ?[]u8 {
    var fs: FsType = .{};
    var file = fs.open(path, .read) orelse return null;
    defer file.close();

    if (file.size == 0) return null;

    const buf = alloc.alloc(u8, file.size) catch return null;
    errdefer alloc.free(buf);

    const loaded = file.readAll(buf) catch return null;
    return buf[0..loaded.len];
}

pub fn run(comptime hw: type, env: anytype) void {
    _ = env;

    const Board = board_spec.Board(hw);
    const time: Board.time = .{};
    const log: Board.log = .{};

    var board: Board = undefined;
    board.init() catch {
        log.err("board init failed");
        return;
    };

    const alloc = if (Board.allocator != void) Board.allocator.default else return;

    var text_ttf_buf: ?[]u8 = null;
    defer if (text_ttf_buf) |buf| alloc.free(buf);
    var icon_ttf_buf: ?[]u8 = null;
    defer if (icon_ttf_buf) |buf| alloc.free(buf);

    var text_ttf_data: []const u8 = embedded_text_ttf_data;
    var icon_ttf_data: []const u8 = embedded_icon_ttf_data;

    if (Board.fs != void) {
        if (!@hasDecl(hw, "mountAssets")) {
            log.err("assets mount missing");
            return;
        }

        hw.mountAssets() catch {
            log.err("mount assets failed");
            return;
        };
        defer if (@hasDecl(hw, "unmountAssets")) hw.unmountAssets();

        text_ttf_buf = loadFontData(Board.fs, alloc, TEXT_FONT_PATH) orelse {
            log.err("load text font failed");
            return;
        };
        icon_ttf_buf = loadFontData(Board.fs, alloc, ICON_FONT_PATH) orelse {
            log.err("load icon font failed");
            return;
        };

        text_ttf_data = text_ttf_buf.?;
        icon_ttf_data = icon_ttf_buf.?;
    }

    log.info("106-lcd: init fonts");

    const text_font = alloc.create(ui.TtfFont) catch {
        log.err("alloc text font failed");
        return;
    };
    defer alloc.destroy(text_font);
    if (!text_font.initInPlace(text_ttf_data, TEXT_FONT_SIZE)) {
        log.err("text font init failed");
        return;
    }

    const icon_font = alloc.create(ui.TtfFont) catch {
        log.err("alloc icon font failed");
        return;
    };
    defer alloc.destroy(icon_font);
    if (!icon_font.initInPlace(icon_ttf_data, ICON_FONT_SIZE)) {
        log.err("icon font init failed");
        return;
    }

    const fb = alloc.create(FB) catch {
        log.err("alloc framebuffer failed");
        return;
    };
    defer alloc.destroy(fb);
    fb.initInPlace(BLACK);

    log.info("106-lcd: drawing icon + Chinese text");

    const icon_w = icon_font.textWidth(ICON_SQUARES_FOUR);
    const zh_w = text_font.textWidth(TITLE_ZH);
    const en_w = text_font.textWidth(TITLE_EN);

    const icon_x = (SCREEN_W -| icon_w) / 2;
    const zh_x = (SCREEN_W -| zh_w) / 2;
    const en_x = (SCREEN_W -| en_w) / 2;

    const icon_y: u16 = 40;
    const zh_y: u16 = 112;
    const en_y: u16 = 150;

    fb.drawTextTtf(icon_x, icon_y, ICON_SQUARES_FOUR, icon_font, ACCENT);
    fb.drawTextTtf(zh_x, zh_y, TITLE_ZH, text_font, WHITE);
    fb.drawTextTtf(en_x, en_y, TITLE_EN, text_font, WHITE);

    fb.flush(&board.display_dev) catch {
        log.err("flush failed");
        return;
    };

    if (@hasDecl(hw, "printRuntimeStats")) {
        hw.printRuntimeStats();
    }
    log.info("106-lcd: done, holding");

    while (Board.isRunning()) {
        time.sleepMs(1000);
    }

    board.deinit();
}
