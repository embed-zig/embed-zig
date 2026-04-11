const Assembler = @import("../../../../Assembler.zig");
const ledstrip = @import("ledstrip");

pub fn testPipelineTickIntervalNs(comptime Lib: type) u64 {
    return Lib.time.ns_per_ms;
}

pub fn makeBuiltApp(
    comptime lib: type,
    comptime Channel: fn (type) type,
    comptime pixel_count: usize,
) type {
    const AssemblerType = Assembler.make(lib, .{
        .max_led_strips = 1,
        .pipeline = .{
            .tick_interval_ns = testPipelineTickIntervalNs(lib),
        },
    }, Channel);
    var assembler = AssemblerType.init();
    assembler.addLedStrip(.strip, 11, pixel_count);
    assembler.setState("ui/led_strip", .{.strip});

    const BuildConfig = assembler.BuildConfig();
    const build_config: BuildConfig = .{
        .strip = ledstrip.LedStrip,
    };
    return assembler.build(build_config);
}

pub fn DummyStrip(comptime pixel_count: usize) type {
    return struct {
        pixels: [pixel_count]ledstrip.Color = [_]ledstrip.Color{ledstrip.Color.black} ** pixel_count,

        fn deinitFn(_: *anyopaque) void {}

        fn countFn(_: *anyopaque) usize {
            return pixel_count;
        }

        fn setPixelFn(ptr: *anyopaque, index: usize, color: ledstrip.Color) void {
            const dummy: *@This() = @ptrCast(@alignCast(ptr));
            if (index >= dummy.pixels.len) return;
            dummy.pixels[index] = color;
        }

        fn pixelFn(ptr: *anyopaque, index: usize) ledstrip.Color {
            const dummy: *@This() = @ptrCast(@alignCast(ptr));
            if (index >= dummy.pixels.len) return ledstrip.Color.black;
            return dummy.pixels[index];
        }

        fn refreshFn(_: *anyopaque) void {}

        const vtable = ledstrip.LedStrip.VTable{
            .deinit = deinitFn,
            .count = countFn,
            .setPixel = setPixelFn,
            .pixel = pixelFn,
            .refresh = refreshFn,
        };

        pub fn handle(dummy: *@This()) ledstrip.LedStrip {
            return .{
                .ptr = dummy,
                .vtable = &vtable,
            };
        }
    };
}

pub fn colorEql(a: ledstrip.Color, b: ledstrip.Color) bool {
    return a.r == b.r and a.g == b.g and a.b == b.b;
}
