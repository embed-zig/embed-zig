const app_options = @import("app_options");
const embed = @import("embed");
const esp = @import("esp");

const grt = esp.grt;
const Board = embed.boards.devkit.Board;

const log = grt.std.log.scoped(.wifi_led_threads);
const LedStateAtomic = grt.std.atomic.Value(u8);
const EventCountAtomic = grt.std.atomic.Value(u32);

const retry_delay: u64 = @intCast(2 * grt.time.duration.Second);
const initial_red_delay: u64 = @intCast(500 * grt.time.duration.MilliSecond);
const connect_timeout_ms: u32 = 15_000;
const blink_interval: u64 = @intCast(250 * grt.time.duration.MilliSecond);

const LedState = enum(u8) {
    red,
    connecting,
    green,
};

const AppState = struct {
    led_state: LedStateAtomic = LedStateAtomic.init(@intFromEnum(LedState.red)),
    wifi_connected_events: EventCountAtomic = EventCountAtomic.init(0),
    wifi_disconnected_events: EventCountAtomic = EventCountAtomic.init(0),
    wifi_got_ip_events: EventCountAtomic = EventCountAtomic.init(0),
    wifi_lost_ip_events: EventCountAtomic = EventCountAtomic.init(0),
    wifi_scan_result_events: EventCountAtomic = EventCountAtomic.init(0),
    wifi: embed.drivers.wifi.Sta,
    strip: embed.ledstrip.LedStrip,
};

var board_impl: Board = undefined;

pub export fn zig_esp_main() void {
    run() catch |err| {
        log.err("wifi_led_threads failed: {s}", .{@errorName(err)});
        @panic("wifi_led_threads failed");
    };
}

fn run() !void {
    board_impl = try Board.init(.{});

    try board_impl.powerOn();
    try board_impl.start();

    const board = board_impl.asBoard();
    var app_state = AppState{
        .wifi = try board.wifiSta("wifi"),
        .strip = try board.ledStrip("strip"),
    };
    app_state.wifi.addEventHook(@ptrCast(&app_state), wifiEventHook);

    const led_task = grt.task.go("wifi_led/led", .{
        .min_stack_size = 4096,
    }, grt.task.Routine.init(&app_state, ledLoop)) catch |err| {
        log.err("failed to spawn led task: {s}", .{@errorName(err)});
        @panic("failed to spawn led task");
    };
    led_task.detach();

    const wifi_task = grt.task.go("wifi_led/wifi", .{
        .min_stack_size = 8192,
    }, grt.task.Routine.init(&app_state, wifiLoop)) catch |err| {
        log.err("failed to spawn wifi task: {s}", .{@errorName(err)});
        @panic("failed to spawn wifi task");
    };
    wifi_task.detach();

    while (true) {
        grt.time.sleep(5 * grt.time.duration.Second);
    }
}

fn wifiLoop(state: *AppState) void {
    var first_attempt = true;
    const ssid = grt.std.mem.sliceTo(app_options.wifi_ssid, 0);

    while (true) {
        setLedState(state, .red);
        grt.time.sleep(if (first_attempt) initial_red_delay else retry_delay);
        first_attempt = false;

        setLedState(state, .connecting);
        log.info("connecting to wifi ssid={s}", .{ssid});

        state.wifi.connect(.{
            .ssid = ssid,
            .password = grt.std.mem.sliceTo(app_options.wifi_password, 0),
            .timeout = @intCast(connect_timeout_ms * grt.time.duration.MilliSecond),
        }) catch |err| {
            log.warn("wifi connect failed: {s}, events connected={d} got_ip={d} disconnected={d}, retrying in 2s", .{
                @errorName(err),
                state.wifi_connected_events.load(.acquire),
                state.wifi_got_ip_events.load(.acquire),
                state.wifi_disconnected_events.load(.acquire),
            });
            continue;
        };

        {
            setLedState(state, .green);
            log.info("wifi connected, events connected={d} got_ip={d} disconnected={d}", .{
                state.wifi_connected_events.load(.acquire),
                state.wifi_got_ip_events.load(.acquire),
                state.wifi_disconnected_events.load(.acquire),
            });
            while (true) {
                grt.time.sleep(5 * grt.time.duration.Second);
            }
        }
    }
}

fn wifiEventHook(ctx: ?*anyopaque, event: embed.drivers.wifi.Sta.Event) void {
    const state: *AppState = @ptrCast(@alignCast(ctx orelse return));
    switch (event) {
        .scan_result => _ = state.wifi_scan_result_events.fetchAdd(1, .monotonic),
        .connected => _ = state.wifi_connected_events.fetchAdd(1, .monotonic),
        .disconnected => _ = state.wifi_disconnected_events.fetchAdd(1, .monotonic),
        .got_ip => _ = state.wifi_got_ip_events.fetchAdd(1, .monotonic),
        .lost_ip => _ = state.wifi_lost_ip_events.fetchAdd(1, .monotonic),
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
                    setLedRgb(state, 32, 0, 0);
                    has_last_state = true;
                    last_state = .red;
                }
                grt.time.sleep(100 * grt.time.duration.MilliSecond);
            },
            .connecting => {
                setLedRgb(state, if (blink_on) 32 else 0, if (blink_on) 24 else 0, 0);
                blink_on = !blink_on;
                has_last_state = true;
                last_state = .connecting;
                grt.time.sleep(blink_interval);
            },
            .green => {
                if (!has_last_state or last_state != .green) {
                    setLedRgb(state, 0, 32, 0);
                    has_last_state = true;
                    last_state = .green;
                }
                grt.time.sleep(250 * grt.time.duration.MilliSecond);
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

fn setLedRgb(state: *AppState, r: u8, g: u8, b: u8) void {
    state.strip.setPixel(0, embed.ledstrip.Color.rgb(r, g, b));
    state.strip.refresh();
}
