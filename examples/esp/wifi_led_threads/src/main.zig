const app_options = @import("app_options");
const esp = @import("esp");

const grt = esp.grt;

const log = grt.std.log.scoped(.wifi_led_threads);
const LedStateAtomic = grt.std.atomic.Value(u8);

const retry_delay: u64 = @intCast(2 * grt.time.duration.Second);
const initial_red_delay: u64 = @intCast(500 * grt.time.duration.MilliSecond);
const connect_timeout_ms: u32 = 15_000;
const blink_interval: u64 = @intCast(250 * grt.time.duration.MilliSecond);
const task_allocator = esp.heap.Allocator(.{ .caps = .internal_8bit });

const LedState = enum(u8) {
    red,
    connecting,
    green,
};

const connect_failed: c_int = 0;
const connect_success: c_int = 1;

const AppState = struct {
    led_state: LedStateAtomic = LedStateAtomic.init(@intFromEnum(LedState.red)),
};

var app_state: AppState = .{};

extern fn esp_example_wifi_led_platform_init(ssid: [*:0]const u8, password: [*:0]const u8) c_int;
extern fn esp_example_wifi_led_platform_connect_blocking(timeout_ms: u32) c_int;
extern fn esp_example_wifi_led_platform_set_rgb(r: u8, g: u8, b: u8) c_int;

pub export fn zig_esp_main() void {
    mustOk(
        "esp_example_wifi_led_platform_init",
        esp_example_wifi_led_platform_init(app_options.wifi_ssid, app_options.wifi_password),
    );

    const led_thread = grt.std.Thread.spawn(.{
        .name = "led_loop",
        .stack_size = 4096,
        .priority = 4,
        .allocator = task_allocator,
    }, ledLoop, .{&app_state}) catch |err| {
        log.err("failed to spawn led thread: {s}", .{@errorName(err)});
        @panic("failed to spawn led thread");
    };
    led_thread.detach();

    const wifi_thread = grt.std.Thread.spawn(.{
        .name = "wifi_loop",
        .stack_size = 8192,
        .priority = 5,
        .allocator = task_allocator,
    }, wifiLoop, .{&app_state}) catch |err| {
        log.err("failed to spawn wifi thread: {s}", .{@errorName(err)});
        @panic("failed to spawn wifi thread");
    };
    wifi_thread.detach();
}

fn wifiLoop(state: *AppState) void {
    var first_attempt = true;
    const ssid = grt.std.mem.sliceTo(app_options.wifi_ssid, 0);

    while (true) {
        setLedState(state, .red);
        grt.std.Thread.sleep(if (first_attempt) initial_red_delay else retry_delay);
        first_attempt = false;

        setLedState(state, .connecting);
        log.info("connecting to wifi ssid={s}", .{ssid});

        const result = esp_example_wifi_led_platform_connect_blocking(connect_timeout_ms);
        if (result == connect_success) {
            setLedState(state, .green);
            log.info("wifi connected", .{});
            while (true) {
                grt.std.Thread.sleep(@intCast(5 * grt.time.duration.Second));
            }
        }
        if (result != connect_failed) {
            log.warn("wifi connect returned unexpected status={d}", .{result});
        } else {
            log.warn("wifi connect failed, retrying in 2s", .{});
        }
    }
}

fn ledLoop(state: *AppState) void {
    var blink_on = false;
    var last_state = LedState.green;
    var has_last_state = false;

    while (true) {
        const next_state = currentLedState(state);
        switch (next_state) {
            .red => {
                if (!has_last_state or last_state != .red) {
                    setLedRgb(32, 0, 0);
                    has_last_state = true;
                    last_state = .red;
                }
                grt.std.Thread.sleep(@intCast(100 * grt.time.duration.MilliSecond));
            },
            .connecting => {
                setLedRgb(if (blink_on) 32 else 0, if (blink_on) 24 else 0, 0);
                blink_on = !blink_on;
                has_last_state = true;
                last_state = .connecting;
                grt.std.Thread.sleep(blink_interval);
            },
            .green => {
                if (!has_last_state or last_state != .green) {
                    setLedRgb(0, 32, 0);
                    has_last_state = true;
                    last_state = .green;
                }
                grt.std.Thread.sleep(@intCast(250 * grt.time.duration.MilliSecond));
            },
        }
    }
}

fn currentLedState(state: *AppState) LedState {
    return @enumFromInt(state.led_state.load(.acquire));
}

fn setLedState(state: *AppState, next_state: LedState) void {
    state.led_state.store(@intFromEnum(next_state), .release);
}

fn setLedRgb(r: u8, g: u8, b: u8) void {
    mustOk("esp_example_wifi_led_platform_set_rgb", esp_example_wifi_led_platform_set_rgb(r, g, b));
}

fn mustOk(name: []const u8, rc: c_int) void {
    if (rc == 0) return;
    log.err("{s} failed with rc={d}", .{ name, rc });
    @panic("esp-idf platform call failed");
}
