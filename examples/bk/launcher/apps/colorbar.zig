const bk = @import("bk");
const consts = @import("colorbar_consts");

const grt = bk.ap.grt;
const log = grt.std.log.scoped(.bk_colorbar_ap);
const Display = bk.embed.drivers.Display;

var display_impl: ?Display = null;
var stripe_pixels: ?[]Display.Rgb = null;
var drawn = false;

pub fn runAp(comptime Board: type) !void {
    const ColorbarApp = Colorbar(Board);
    const task = try grt.task.go("bk/colorbar/ap", .{
        .min_stack_size = 4096,
    }, grt.task.Routine.init(&ColorbarApp.task_state, ColorbarApp.task));
    task.detach();
}

fn Colorbar(comptime Board: type) type {
    return struct {
        const Self = @This();
        var task_state: Self = .{};

        fn task(self: *Self) void {
            _ = self;
            log.info("zux colorbar app start board={s}", .{Board.name});
            while (true) {
                if (!drawn) {
                    drawOnce() catch |err| {
                        log.err("zux colorbar draw failed: {}", .{err});
                    };
                }
                grt.time.sleepNanos(@intCast(5 * grt.time.duration.Second));
                log.info("zux colorbar alive drawn={}", .{drawn});
            }
        }

        fn drawOnce() !void {
            if (display_impl == null) {
                display_impl = try bk.embed.display.Rgb.display(.{
                    .allocator = bk.heap.psram_allocator,
                    .max_flush_rows = 64,
                });
                const display = display_impl.?;
                try display.setEnabled(true);
                try display.setBrightness(255);
                log.info("display init ok size={}x{}", .{ display.width(), display.height() });
            }

            if (drawn) return;

            const display = display_impl.?;
            const width_px = display.width();
            const height_px = display.height();
            const stripe_count = consts.color.split.len;
            const max_stripe_width: u16 = @intCast((@as(usize, width_px) + stripe_count - 1) / stripe_count);
            const max_count = @as(usize, max_stripe_width) * @as(usize, height_px);

            if (stripe_pixels == null) {
                stripe_pixels = try bk.heap.psram_allocator.alloc(Display.Rgb, max_count);
            }

            const pixels = stripe_pixels.?;
            for (consts.color.split, 0..) |hex, index| {
                const x0: u16 = @intCast((index * @as(usize, width_px)) / stripe_count);
                const x1: u16 = @intCast(((index + 1) * @as(usize, width_px)) / stripe_count);
                const stripe_width = x1 - x0;
                const count = @as(usize, stripe_width) * @as(usize, height_px);
                const color = rgbFromHex(hex);

                for (pixels[0..count]) |*pixel| {
                    pixel.* = color;
                }
                try display.drawBitmap(x0, 0, stripe_width, height_px, pixels[0..count]);
            }

            drawn = true;
            log.info("zux colorbar drawn bars={} size={}x{}", .{
                stripe_count,
                width_px,
                height_px,
            });
        }

        fn rgbFromHex(hex: u32) Display.Rgb {
            return Display.rgb(
                @intCast((hex >> 16) & 0xff),
                @intCast((hex >> 8) & 0xff),
                @intCast(hex & 0xff),
            );
        }
    };
}
