pub const runtime = struct {
    pub const errors = @import("runtime/errors.zig");
    pub const sync = @import("runtime/sync.zig");
    pub const time = @import("runtime/time.zig");
    pub const thread = @import("runtime/thread.zig");
    pub const system = @import("runtime/system.zig");
    pub const io = @import("runtime/io.zig");
    pub const socket = @import("runtime/socket.zig");
    pub const fs = @import("runtime/fs.zig");
    pub const log = @import("runtime/log.zig");
    pub const rng = @import("runtime/rng.zig");
    pub const netif = @import("runtime/netif.zig");
    pub const ota_backend = @import("runtime/ota_backend.zig");
    pub const std = @import("runtime/std.zig");

    pub const crypto = struct {
        pub const hash = @import("runtime/crypto/hash.zig");
        pub const hmac = @import("runtime/crypto/hmac.zig");
        pub const hkdf = @import("runtime/crypto/hkdf.zig");
        pub const aead = @import("runtime/crypto/aead.zig");
        pub const pki = @import("runtime/crypto/pki.zig");
        pub const suite = @import("runtime/crypto/suite.zig");
    };
};

pub const hal = struct {
    pub const marker = @import("hal/marker.zig");
    pub const board = @import("hal/board.zig");
    pub const gpio = @import("hal/gpio.zig");
    pub const adc = @import("hal/adc.zig");
    pub const pwm = @import("hal/pwm.zig");
    pub const i2c = @import("hal/i2c.zig");
    pub const i2s = @import("hal/i2s.zig");
    pub const spi = @import("hal/spi.zig");
    pub const uart = @import("hal/uart.zig");
    pub const wifi = @import("hal/wifi.zig");
    pub const hci = @import("hal/hci.zig");
    pub const kvs = @import("hal/kvs.zig");
    pub const rtc = @import("hal/rtc.zig");
    pub const led = @import("hal/led.zig");
    pub const led_strip = @import("hal/led_strip.zig");
    pub const display = @import("hal/display.zig");
    pub const speaker = @import("hal/speaker.zig");
    pub const mic = @import("hal/mic.zig");
    pub const audio_system = @import("hal/audio_system.zig");
    pub const temp_sensor = @import("hal/temp_sensor.zig");
    pub const imu = @import("hal/imu.zig");
};

pub const pkg = struct {
    pub const async = struct {
        pub const cancellation = @import("pkg/async/cancellation.zig");
        pub const channel = @import("pkg/async/channel.zig");
        pub const waitgroup = @import("pkg/async/wait_group.zig");
        pub const timer = @import("pkg/async/timer.zig");
        pub const reactor = @import("pkg/async/reactor.zig");
        pub const executor = @import("pkg/async/executor.zig");

        pub const Source = cancellation.Source;
        pub const Token = cancellation.Token;
        pub const Channel = channel.Channel;
        pub const WaitGroup = waitgroup.WaitGroup;
        pub const Scheduler = timer.Scheduler;
        pub const TimerId = timer.TimerId;
        pub const Reactor = reactor.Reactor;
        pub const Executor = executor.Executor;
    };

    pub const audio = struct {
        pub const engine = @import("pkg/audio/engine.zig");
        pub const mixer = @import("pkg/audio/mixer.zig");
        pub const override_buffer = @import("pkg/audio/override_buffer.zig");
        pub const resampler = @import("pkg/audio/resampler.zig");

        pub const Engine = engine.Engine;
        pub const Mixer = mixer.Mixer;
        pub const Format = resampler.Format;
        pub const Beamformer = engine.Beamformer;
        pub const Processor = engine.Processor;
        pub const PassthroughBeamformer = engine.PassthroughBeamformer;
        pub const PassthroughProcessor = engine.PassthroughProcessor;
    };

    pub const ble = struct {
        pub const gatt = struct {
            pub const server = @import("pkg/ble/gatt/server.zig");
            pub const client = @import("pkg/ble/gatt/client.zig");
        };

        pub const host = struct {
            const host_mod = @import("pkg/ble/host/host.zig");
            pub const Host = host_mod.Host;
            pub const hci = struct {
                pub const hci = @import("pkg/ble/host/hci/hci.zig");
                pub const acl = @import("pkg/ble/host/hci/acl.zig");
                pub const commands = @import("pkg/ble/host/hci/commands.zig");
                pub const events = @import("pkg/ble/host/hci/events.zig");
            };
            pub const att = struct {
                pub const att = @import("pkg/ble/host/att/att.zig");
            };
            pub const gap = struct {
                pub const gap = @import("pkg/ble/host/gap/gap.zig");
            };
            pub const l2cap = struct {
                pub const l2cap = @import("pkg/ble/host/l2cap/l2cap.zig");
            };
        };

        pub const xfer = @import("pkg/ble/xfer/api.zig");
        pub const term = @import("pkg/ble/term/api.zig");

        pub const hci = host.hci;
        pub const att = host.att;
        pub const gap = host.gap;
        pub const l2cap = host.l2cap;
    };

    pub const drivers = struct {
        pub const es7210 = @import("pkg/drivers/es7210/src.zig");
        pub const es8311 = @import("pkg/drivers/es8311/src.zig");
        pub const qmi8658 = @import("pkg/drivers/qmi8658/src.zig");
        pub const tca9554 = @import("pkg/drivers/tca9554/src.zig");
    };

    pub const event = struct {
        pub const types = @import("pkg/event/types.zig");
        pub const bus = @import("pkg/event/bus.zig");
        pub const middleware = @import("pkg/event/middleware.zig");
        pub const logger = @import("pkg/event/logger.zig");
        pub const ring_buffer = @import("pkg/event/ring_buffer.zig");

        pub const PeriphEvent = types.PeriphEvent;
        pub const CustomEvent = types.CustomEvent;
        pub const TimerEvent = types.TimerEvent;
        pub const SystemEvent = types.SystemEvent;
        pub const Bus = bus.Bus;
        pub const Periph = bus.Periph;
        pub const Middleware = middleware.Middleware;
        pub const EmitFn = middleware.EmitFn;
        pub const Logger = logger.Logger;
        pub const RingBuffer = ring_buffer.RingBuffer;

        pub const button = struct {
            pub const gesture = @import("pkg/event/button/gesture.zig");
            pub const GestureCode = gesture.GestureCode;
            pub const ButtonGesture = gesture.ButtonGesture;

            pub const gpio = struct {
                const button_mod = @import("pkg/event/button/gpio/button.zig");
                pub const GpioButton = button_mod.Button;
            };

            pub const adc = struct {
                const adc_button_mod = @import("pkg/event/button/adc/adc_button.zig");
                pub const AdcButtonSet = adc_button_mod.AdcButtonSet;
                pub const AdcButtonConfig = adc_button_mod.Config;
            };

            pub const GpioButton = gpio.GpioButton;
            pub const AdcButtonSet = adc.AdcButtonSet;
            pub const AdcButtonConfig = adc.AdcButtonConfig;
        };

        pub const motion = struct {
            pub const motion = @import("pkg/event/motion/motion.zig");
            pub const detector = @import("pkg/event/motion/detector.zig");
            pub const types = @import("pkg/event/motion/types.zig");
            pub const peripheral = @import("pkg/event/motion/peripheral.zig");
            const motion_mod = @import("pkg/event/motion/motion.zig");
            const detector_mod = @import("pkg/event/motion/detector.zig");
            const peripheral_mod = @import("pkg/event/motion/peripheral.zig");

            pub const MotionAction = motion_mod.MotionAction;
            pub const Detector = detector_mod.Detector;
            pub const MotionPeripheral = peripheral_mod.MotionPeripheral;
        };

        pub const timer = struct {
            pub const timer = @import("pkg/event/timer/timer.zig");
            const timer_mod = @import("pkg/event/timer/timer.zig");
            pub const TimerPayload = timer_mod.TimerPayload;
            pub const TimerSource = timer_mod.TimerSource;
        };
    };

    pub const flux = struct {
        pub const store = @import("pkg/flux/store.zig");
        pub const app_state_manager = @import("pkg/flux/app_state_manager.zig");
        pub const Store = store.Store;
        pub const AppStateManager = app_state_manager.AppStateManager;
    };

    pub const net = struct {
        pub const conn = @import("pkg/net/conn.zig");
        pub const Conn = conn.from;
        pub const SocketConn = conn.SocketConn;

        pub const dns = @import("pkg/net/dns/dns.zig");
        pub const ntp = @import("pkg/net/ntp/ntp.zig");
        pub const url = @import("pkg/net/url/url.zig");
        pub const ws = struct {
            pub const frame = @import("pkg/net/ws/frame.zig");
            pub const handshake = @import("pkg/net/ws/handshake.zig");
            pub const client = @import("pkg/net/ws/client.zig");
            pub const sha1 = @import("pkg/net/ws/sha1.zig");
            pub const base64 = @import("pkg/net/ws/base64.zig");

            pub const Client = client.Client;
            pub const Message = client.Message;
            pub const MessageType = client.MessageType;
            pub const copyForward = client.copyForward;
        };

        pub const tls = struct {
            pub const common = @import("pkg/net/tls/common.zig");
            pub const record = @import("pkg/net/tls/record.zig");
            pub const handshake = @import("pkg/net/tls/handshake.zig");
            pub const alert = @import("pkg/net/tls/alert.zig");
            pub const extensions = @import("pkg/net/tls/extensions.zig");
            pub const client = @import("pkg/net/tls/client.zig");
            pub const stream = @import("pkg/net/tls/stream.zig");
            pub const kdf = @import("pkg/net/tls/kdf.zig");
            pub const cert = @import("pkg/net/tls/cert/certs.zig");

            pub const Client = client.Client;
            pub const Stream = stream.Stream;
            pub const connect = client.connect;
        };

        pub const http = struct {
            pub const transport = @import("pkg/net/http/transport.zig");
            pub const client = @import("pkg/net/http/client.zig");
            pub const request = @import("pkg/net/http/request.zig");
            pub const response = @import("pkg/net/http/response.zig");
            pub const router = @import("pkg/net/http/router.zig");
            pub const static = @import("pkg/net/http/static.zig");
            pub const server_mod = @import("pkg/net/http/server.zig");
        };
    };

    pub const ui = struct {
        pub const render = struct {
            pub const framebuffer = @import("pkg/ui/render/framebuffer/framebuffer.zig");
            pub const fb_font = @import("pkg/ui/render/framebuffer/font.zig");
            pub const image = @import("pkg/ui/render/framebuffer/image.zig");
            pub const dirty = @import("pkg/ui/render/framebuffer/dirty.zig");
            pub const anim = @import("pkg/ui/render/framebuffer/anim.zig");
            pub const scene = @import("pkg/ui/render/framebuffer/scene.zig");

            pub const ttf_font = @import("pkg/ui/render/framebuffer/ttf_font.zig");

            pub const Framebuffer = framebuffer.Framebuffer;
            pub const ColorFormat = framebuffer.ColorFormat;
            pub const BitmapFont = fb_font.BitmapFont;
            pub const TtfFont = ttf_font.TtfFont;
            pub const asciiLookup = fb_font.asciiLookup;
            pub const decodeUtf8 = fb_font.decodeUtf8;
            pub const Image = image.Image;
            pub const Rect = dirty.Rect;
            pub const DirtyTracker = dirty.DirtyTracker;
            pub const AnimPlayer = anim.AnimPlayer;
            pub const AnimFrame = anim.AnimFrame;
            pub const blitAnimFrame = anim.blitAnimFrame;
            pub const Compositor = scene.Compositor;
            pub const Region = scene.Region;
            pub const SceneRenderer = scene.SceneRenderer;
        };

        pub const font = @import("pkg/ui/render/font/api.zig");
        pub const led_strip = struct {
            pub const frame = @import("pkg/ui/led_strip/frame.zig");
            pub const animator = @import("pkg/ui/led_strip/animator.zig");
            pub const transition = @import("pkg/ui/led_strip/transition.zig");

            pub const Frame = frame.Frame;
            pub const Color = frame.Color;
            pub const Animator = animator.Animator;
        };
    };

    pub const app = @import("pkg/app/app_runtime.zig");
};

pub const third_party = @import("third_party");

pub const websim = struct {
    pub const server = @import("websim/server.zig");
    pub const remote_hal = @import("websim/remote_hal.zig");
    pub const ws = @import("websim/ws.zig");
    pub const outbox = @import("websim/outbox.zig");
    pub const yaml_case = @import("websim/yaml_case.zig");
    pub const test_runner = @import("websim/test_runner.zig");

    pub const RemoteHal = remote_hal.RemoteHal;
    pub const Outbox = outbox.Outbox;
    pub const DevRouter = outbox.DevRouter;
    pub const serve = server.serve;
    pub const ServeOptions = server.ServeOptions;
    pub const runTestDir = test_runner.runTestDir;

    pub const hal = struct {
        pub const gpio = @import("websim/hal/gpio.zig");
        pub const led_strip = @import("websim/hal/led_strip.zig");
        pub const rtc = @import("websim/hal/rtc.zig");
        pub const display = @import("websim/hal/display.zig");

        pub const Gpio = gpio.Gpio;
        pub const LedStrip = led_strip.LedStrip;
        pub const Rtc = rtc.Rtc;
        pub const Display = display.Display;
    };
};

test {
    std.testing.refAllDecls(@This());
    _ = @import("runtime/std.zig");
    _ = @import("pkg/audio/engine.zig");
    _ = @import("pkg/audio/mixer.zig");
    _ = @import("pkg/audio/override_buffer.zig");
    _ = @import("pkg/audio/resampler.zig");
    _ = @import("pkg/event/bus_integration_test.zig");
    _ = @import("pkg/net/tls/stress_test.zig");
    _ = @import("pkg/net/ws/e2e_test.zig");
    _ = @import("pkg/ble/xfer/xfer_test.zig");
    _ = @import("pkg/ble/term/term_test.zig");
    _ = @import("pkg/ble/ble_test.zig");
    _ = @import("pkg/ui/render/framebuffer/dirty.zig");
    _ = @import("pkg/ui/render/framebuffer/framebuffer.zig");
    _ = @import("pkg/ui/render/framebuffer/font.zig");
    _ = @import("pkg/ui/render/framebuffer/image.zig");
    _ = @import("pkg/ui/render/framebuffer/anim.zig");
    _ = @import("pkg/ui/render/framebuffer/scene.zig");
    _ = @import("pkg/ui/render/font/api.zig");
    _ = @import("pkg/ui/led_strip/frame.zig");
    _ = @import("pkg/ui/led_strip/transition.zig");
    _ = @import("pkg/ui/led_strip/animator.zig");
    _ = @import("pkg/flux/store.zig");
    _ = @import("pkg/flux/app_state_manager.zig");
    _ = @import("pkg/app/app_runtime.zig");
}

const std = @import("std");

const Ch = pkg.async.Channel(u32, runtime.std.Mutex, runtime.std.Condition);
const Wg = pkg.async.WaitGroup(runtime.std.Mutex, runtime.std.Condition);
const Exec = pkg.async.Executor(runtime.std.Mutex);
const React = pkg.async.Reactor(runtime.std.IO);

test "integration: executor tasks communicate through channel" {
    var ch = try Ch.init(std.testing.allocator, 16);
    defer ch.deinit();

    const Sender = struct {
        ch_ptr: *Ch,
        fn run(raw: ?*anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(raw orelse return));
            var i: u32 = 0;
            while (i < 10) : (i += 1) {
                self.ch_ptr.trySend(i) catch return error.ChannelFull;
            }
        }
    };

    var sender = Sender{ .ch_ptr = &ch };
    var exec = Exec.init(std.testing.allocator);
    defer exec.deinit();

    try exec.submit(.{ .func = Sender.run, .ctx = &sender });
    try exec.runAll();

    try std.testing.expectEqual(@as(usize, 1), exec.stats().completed);
    try std.testing.expectEqual(@as(usize, 10), ch.count());

    var sum: u64 = 0;
    while (!ch.isEmpty()) {
        sum += try ch.tryRecv();
    }
    try std.testing.expectEqual(@as(u64, 45), sum);
}

test "integration: cancellation aborts executor tasks and timer" {
    var cancel_src = pkg.async.Source{};

    var sched = pkg.async.Scheduler.init(std.testing.allocator);
    defer sched.deinit();

    _ = try sched.scheduleWithCallback(0, 100, null, null, &cancel_src);
    _ = try sched.scheduleWithCallback(0, 200, null, null, &cancel_src);

    const tok = cancel_src.token();

    const noop = struct {
        fn run(_: ?*anyopaque) !void {}
    }.run;

    var exec = Exec.init(std.testing.allocator);
    defer exec.deinit();

    try exec.submit(.{ .func = noop, .ctx = null, .cancel_token = tok });
    try exec.submit(.{ .func = noop, .ctx = null, .cancel_token = tok });
    try exec.submit(.{ .func = noop, .ctx = null });

    _ = cancel_src.cancel();

    try exec.runAll();
    try std.testing.expectEqual(@as(usize, 1), exec.stats().completed);
    try std.testing.expectEqual(@as(usize, 2), exec.stats().cancelled);

    var ready = std.ArrayList(pkg.async.TimerId).empty;
    defer ready.deinit(std.testing.allocator);
    try sched.collectReady(300, &ready);
    try std.testing.expectEqual(@as(usize, 0), ready.items.len);
}

test "integration: waitgroup tracks executor task completion" {
    var wg = Wg.init();
    defer wg.deinit();

    const Counter = struct {
        var done_count: usize = 0;
        fn onAllDone(_: ?*anyopaque) void {
            done_count = 1;
        }
    };
    Counter.done_count = 0;
    wg.onComplete(Counter.onAllDone, null);
    wg.add(3);

    const TaskCtx = struct {
        wg_ptr: *Wg,
        fn run(raw: ?*anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(raw orelse return));
            self.wg_ptr.done() catch {};
        }
    };

    var ctx1 = TaskCtx{ .wg_ptr = &wg };
    var ctx2 = TaskCtx{ .wg_ptr = &wg };
    var ctx3 = TaskCtx{ .wg_ptr = &wg };

    var exec = Exec.init(std.testing.allocator);
    defer exec.deinit();

    try exec.submit(.{ .func = TaskCtx.run, .ctx = &ctx1 });
    try exec.submit(.{ .func = TaskCtx.run, .ctx = &ctx2 });
    try exec.submit(.{ .func = TaskCtx.run, .ctx = &ctx3 });

    try exec.runAll();
    try std.testing.expectEqual(@as(usize, 3), exec.stats().completed);
    try std.testing.expect(wg.isDone());
    try std.testing.expectEqual(@as(usize, 1), Counter.done_count);
}

test "integration: reactor timer drives executor task scheduling" {
    var io = try runtime.std.IO.init(std.testing.allocator);
    defer io.deinit();
    var reactor = React.init(&io, std.testing.allocator);
    defer reactor.deinit();

    const TaskState = struct {
        var timer_fired: bool = false;
        fn onTimer(_: ?*anyopaque) void {
            timer_fired = true;
        }
    };
    TaskState.timer_fired = false;

    _ = try reactor.scheduleTimerWithCallback(0, 50, TaskState.onTimer, null, null);

    var ready = std.ArrayList(pkg.async.TimerId).empty;
    defer ready.deinit(std.testing.allocator);

    const events = try reactor.tick(50, &ready);
    try std.testing.expectEqual(@as(usize, 1), events);
    try std.testing.expect(TaskState.timer_fired);

    const noop = struct {
        fn run(_: ?*anyopaque) !void {}
    }.run;

    var exec = Exec.init(std.testing.allocator);
    defer exec.deinit();

    for (ready.items) |_| {
        try exec.submit(.{ .func = noop, .ctx = null });
    }
    try exec.runAll();
    try std.testing.expectEqual(@as(usize, 1), exec.stats().completed);
}

test "integration: channel producer cancelled mid-stream" {
    var ch = try Ch.init(std.testing.allocator, 32);
    defer ch.deinit();

    var cancel_src = pkg.async.Source{};
    const tok = cancel_src.token();

    const Producer = struct {
        ch_ptr: *Ch,
        token: pkg.async.Token,
        fn run(raw: ?*anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(raw orelse return));
            var i: u32 = 0;
            while (i < 100) : (i += 1) {
                if (self.token.isCancelled()) return;
                self.ch_ptr.trySend(i) catch return;
            }
        }
    };

    var producer = Producer{ .ch_ptr = &ch, .token = tok };

    var exec = Exec.init(std.testing.allocator);
    defer exec.deinit();

    ch.trySend(0) catch {};
    ch.trySend(1) catch {};
    ch.trySend(2) catch {};

    _ = cancel_src.cancel();

    try exec.submit(.{ .func = Producer.run, .ctx = &producer });
    try exec.runAll();

    try std.testing.expectEqual(@as(usize, 3), ch.count());
}
