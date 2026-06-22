const bk = @import("bk");

const grt = bk.ap.grt;
const log = grt.std.log.scoped(.bk_smoke_ap);
const EmbedWifiSta = bk.embed.drivers.wifi.Sta;
const Display = bk.embed.drivers.Display;

const Channel = grt.sync.Channel(u32);

const LFS_FLASH: c_int = 2;
const O_RDONLY: c_int = 0;
const O_RDWR: c_int = 2;
const O_CREAT: c_int = 0x0200;
const O_TRUNC: c_int = 0x0400;

const FlashPart = extern struct {
    start_addr: u32,
    size: u32,
};

const LittleFsPartition = extern struct {
    part_type: c_int,
    mount_path: [*c]const u8,
    part_flash: FlashPart,
};

extern fn easyflash_init() c_int;
extern fn bk_set_env_enhance(key: [*:0]const u8, value: ?*const anyopaque, value_len: c_int) c_int;
extern fn bk_get_env_enhance(key: [*:0]const u8, value: ?*anyopaque, value_len: c_int) c_int;
extern fn bk_vfs_init() c_int;
extern fn bk_vfs_mount(source: [*:0]const u8, target: [*:0]const u8, fs_type: [*:0]const u8, mount_flags: c_ulong, data: ?*const anyopaque) c_int;
extern fn bk_vfs_open(path: [*:0]const u8, flags: c_int) c_int;
extern fn bk_vfs_read(fd: c_int, buf: ?*anyopaque, count: usize) isize;
extern fn bk_vfs_write(fd: c_int, buf: ?*const anyopaque, count: usize) isize;
extern fn bk_vfs_close(fd: c_int) c_int;

var heartbeat_count: u32 = 0;
var wifi_sta_impl: bk.embed.Wifi.Sta = .{};
var wifi_sta_ready = false;
var wifi_scan_results: u32 = 0;
var display_ready = false;
var display_drawn = false;
var display_impl: ?Display = null;
var display_pixels: ?[]Display.Rgb = null;

pub fn runAp(comptime Board: type) !void {
    const SmokeApp = Smoke(Board);
    const task = try grt.task.go("bk/smoke/ap", .{
        .min_stack_size = 2048,
    }, grt.task.Routine.init(&SmokeApp.ap_task, SmokeApp.apHeartbeatTask));
    task.detach();
}

fn Smoke(comptime Board: type) type {
    return struct {
        const Self = @This();
        var ap_task: Self = .{};

        fn heartbeatCount() u32 {
            const value = heartbeat_count;
            heartbeat_count +%= 1;
            return value;
        }

        fn channelProducer(channel: *Channel) void {
            _ = channel.send(0xA725_8001) catch |err| {
                log.err("AP channel send failed: {}", .{err});
                return;
            };
        }

        fn runThreadAndChannelSmoke() void {
            const cpu_count = grt.system.cpuCount() catch 0;
            log.info("thread cpu_count={}", .{cpu_count});

            var channel = Channel.make(bk.heap.allocator, 2) catch |err| {
                log.err("AP channel create failed: {}", .{err});
                return;
            };
            defer channel.deinit();

            const task = grt.task.go("bk/smoke/channel", .{
                .min_stack_size = 2048,
            }, grt.task.Routine.init(&channel, channelProducer)) catch |err| {
                log.err("AP channel producer task failed: {}", .{err});
                return;
            };
            task.detach();

            const result = channel.recvTimeout(2 * grt.time.duration.Second) catch |err| {
                log.err("AP channel recv failed: {}", .{err});
                return;
            };
            if (!result.ok or result.value != 0xA725_8001) {
                log.err("AP channel smoke failed ok={} value=0x{x}", .{ result.ok, result.value });
                return;
            }
            log.info("AP channel smoke ok value=0x{x}", .{result.value});
        }

        fn runEasyFlashSmoke() void {
            const init_rc = easyflash_init();
            if (init_rc != 0) {
                log.err("AP easyflash init failed rc={}", .{init_rc});
                return;
            }

            const key = "smoke_ap_u32";
            var value: u32 = heartbeatCount() + 1000;
            const set_rc = bk_set_env_enhance(key, @ptrCast(&value), @sizeOf(u32));
            if (set_rc != 0) {
                log.err("AP easyflash set failed rc={}", .{set_rc});
                return;
            }

            var read_back: u32 = 0;
            const get_rc = bk_get_env_enhance(key, @ptrCast(&read_back), @sizeOf(u32));
            if (get_rc <= 0 or read_back != value) {
                log.err("AP easyflash get failed rc={} value={}", .{ get_rc, read_back });
                return;
            }

            log.info("AP easyflash smoke ok len={} value={}", .{ get_rc, read_back });
        }

        fn runLittleFsSmoke() void {
            const vfs_rc = bk_vfs_init();
            if (vfs_rc != 0) {
                log.err("AP vfs init failed rc={}", .{vfs_rc});
                return;
            }

            const mount_path: [:0]const u8 = Board.littlefs_mount_path;
            var partition = LittleFsPartition{
                .part_type = LFS_FLASH,
                .mount_path = mount_path.ptr,
                .part_flash = .{
                    .start_addr = Board.littlefs_offset,
                    .size = Board.littlefs_size_bytes,
                },
            };
            const mount_rc = bk_vfs_mount("SOURCE_NONE", mount_path, "littlefs", 0, &partition);
            if (mount_rc != 0) {
                log.err("AP littlefs mount failed rc={}", .{mount_rc});
                return;
            }

            const hello_path: [:0]const u8 = Board.littlefs_mount_path ++ "/hello.txt";
            const hello_fd = bk_vfs_open(hello_path, O_RDONLY);
            if (hello_fd < 0) {
                log.err("AP littlefs open hello failed fd={}", .{hello_fd});
                return;
            }
            var hello_buf: [96]u8 = undefined;
            const hello_len = bk_vfs_read(hello_fd, &hello_buf, hello_buf.len);
            _ = bk_vfs_close(hello_fd);
            if (hello_len <= 0) {
                log.err("AP littlefs read hello failed len={}", .{hello_len});
                return;
            }
            const hello_size: usize = @intCast(hello_len);
            log.info("AP littlefs read ok len={} text={s}", .{ hello_size, hello_buf[0..hello_size] });

            const runtime_path: [:0]const u8 = Board.littlefs_mount_path ++ "/runtime.txt";
            const runtime_fd = bk_vfs_open(runtime_path, O_RDWR | O_CREAT | O_TRUNC);
            if (runtime_fd < 0) {
                log.err("AP littlefs open runtime failed fd={}", .{runtime_fd});
                return;
            }
            const runtime_text = "hello from AP runtime\n";
            const write_len = bk_vfs_write(runtime_fd, runtime_text.ptr, runtime_text.len);
            _ = bk_vfs_close(runtime_fd);
            if (write_len != runtime_text.len) {
                log.err("AP littlefs write runtime failed len={}", .{write_len});
                return;
            }
            log.info("AP littlefs write ok len={}", .{write_len});
        }

        fn runAllocatorSmoke() void {
            runOneAllocatorSmoke("internal", bk.heap.allocator);
            runOneAllocatorSmoke("psram", bk.heap.psram_allocator);
        }

        fn runOneAllocatorSmoke(name: []const u8, allocator: grt.std.mem.Allocator) void {
            const memory = allocator.alloc(u8, 64) catch |err| {
                log.err("AP {s} allocator failed: {}", .{ name, err });
                return;
            };
            defer allocator.free(memory);

            @memset(memory, 0x5a);
            if (memory[0] != 0x5a or memory[memory.len - 1] != 0x5a) {
                log.err("AP {s} allocator memory check failed", .{name});
                return;
            }
            log.info("AP {s} allocator smoke ok len={}", .{ name, memory.len });
        }

        fn runNetSmoke() void {
            const any = grt.net.netip.AddrPort.from4(.{ 0, 0, 0, 0 }, 0);

            var udp = grt.net.Runtime.udp(.inet) catch |err| {
                log.err("AP udp create failed: {}", .{err});
                return;
            };
            defer {
                udp.close();
                udp.deinit();
            }
            udp.setOpt(.{ .socket = .{ .reuse_addr = true } }) catch |err| {
                log.err("AP udp reuse_addr failed: {}", .{err});
                return;
            };
            udp.bind(any) catch |err| {
                log.err("AP udp bind failed: {}", .{err});
                return;
            };
            const udp_addr = udp.localAddr() catch |err| {
                log.err("AP udp local addr failed: {}", .{err});
                return;
            };
            log.info("AP udp smoke ok port={}", .{udp_addr.port()});

            var tcp = grt.net.Runtime.tcp(.inet) catch |err| {
                log.err("AP tcp create failed: {}", .{err});
                return;
            };
            defer {
                tcp.close();
                tcp.deinit();
            }
            tcp.setOpt(.{ .socket = .{ .reuse_addr = true } }) catch |err| {
                log.err("AP tcp reuse_addr failed: {}", .{err});
                return;
            };
            tcp.bind(any) catch |err| {
                log.err("AP tcp bind failed: {}", .{err});
                return;
            };
            tcp.listen(1) catch |err| {
                log.err("AP tcp listen failed: {}", .{err});
                return;
            };
            const tcp_addr = tcp.localAddr() catch |err| {
                log.err("AP tcp local addr failed: {}", .{err});
                return;
            };
            log.info("AP tcp smoke ok port={}", .{tcp_addr.port()});
        }

        fn wifiEventHook(_: ?*anyopaque, event: EmbedWifiSta.Event) void {
            switch (event) {
                .scan_result => |ap| {
                    const index = wifi_scan_results;
                    wifi_scan_results +%= 1;
                    if (index < 8) {
                        log.info(
                            "AP wifi scan result ssid={s} rssi={} channel={} security={s}",
                            .{ ap.ssid, ap.rssi, ap.channel, @tagName(ap.security) },
                        );
                    }
                },
                .connected => |link| {
                    log.info("AP wifi connected ssid={s} rssi={}", .{ link.ssid, link.rssi });
                },
                .disconnected => |info| {
                    log.info("AP wifi disconnected reason={}", .{info.reason});
                },
                .got_ip => |_| {
                    log.info("AP wifi got ip", .{});
                },
                .lost_ip => {
                    log.info("AP wifi lost ip", .{});
                },
            }
        }

        fn runWifiStaSmoke() void {
            if (!wifi_sta_ready) {
                wifi_sta_impl.init() catch |err| {
                    log.err("AP wifi init failed: {}", .{err});
                    return;
                };
                const sta = wifi_sta_impl.handle();
                sta.addEventHook(null, wifiEventHook);
                wifi_sta_ready = true;

                if (sta.getMacAddr()) |mac| {
                    log.info(
                        "AP wifi mac {x}:{x}:{x}:{x}:{x}:{x}",
                        .{ mac[0], mac[1], mac[2], mac[3], mac[4], mac[5] },
                    );
                } else {
                    log.err("AP wifi mac unavailable", .{});
                }

                sta.setPowerSave(.none) catch |err| {
                    log.err("AP wifi power save setup failed: {}", .{err});
                };
            }

            const sta = wifi_sta_impl.handle();
            wifi_scan_results = 0;
            sta.startScan(.{
                .active = true,
                .timeout = 3 * grt.time.duration.Second,
            }) catch |err| {
                log.err("AP wifi scan start failed: {}", .{err});
                return;
            };
            log.info("AP wifi scan started state={s}", .{@tagName(sta.getState())});
        }

        fn runDisplaySmoke() void {
            if (!display_ready) {
                display_impl = bk.embed.display.Qspi.display(.{
                    .allocator = bk.heap.psram_allocator,
                }) catch |err| {
                    log.err("AP display init failed: {}", .{err});
                    return;
                };
                const display = display_impl.?;
                display.setEnabled(true) catch |err| {
                    log.err("AP display enable failed: {}", .{err});
                    return;
                };
                display.setBrightness(255) catch |err| {
                    log.err("AP display brightness failed: {}", .{err});
                    return;
                };
                display_ready = true;
                log.info("AP display init ok size={}x{}", .{ display.width(), display.height() });
            }

            if (display_drawn) return;

            const display = display_impl.?;
            const width_px = display.width();
            const height_px = display.height();
            const count = @as(usize, width_px) * @as(usize, height_px);
            if (display_pixels == null) {
                display_pixels = bk.heap.psram_allocator.alloc(Display.Rgb, count) catch |err| {
                    log.err("AP display pixel buffer alloc failed: {}", .{err});
                    return;
                };
            }

            const pixels = display_pixels.?;
            for (0..height_px) |y| {
                for (0..width_px) |x| {
                    pixels[y * @as(usize, width_px) + x] = colorForX(@intCast(x), width_px);
                }
            }

            display.drawBitmap(0, 0, width_px, height_px, pixels) catch |err| {
                log.err("AP display draw failed: {}", .{err});
                return;
            };
            display_drawn = true;
            log.info("AP display colorbar drawn", .{});
        }

        fn colorForX(x: u16, width_px: u16) Display.Rgb {
            const stripe = (@as(u32, x) * color_table.len) / width_px;
            return color_table[@intCast(stripe)];
        }

        const color_table = [_]Display.Rgb{
            Display.rgb(255, 255, 255),
            Display.rgb(255, 255, 0),
            Display.rgb(0, 255, 255),
            Display.rgb(0, 255, 0),
            Display.rgb(255, 0, 255),
            Display.rgb(255, 0, 0),
            Display.rgb(0, 0, 255),
            Display.rgb(0, 0, 0),
        };

        fn runSmokeSuite() void {
            runAllocatorSmoke();
            runThreadAndChannelSmoke();
            runNetSmoke();
            runWifiStaSmoke();
            runDisplaySmoke();
            runEasyFlashSmoke();
            runLittleFsSmoke();
        }

        fn apHeartbeatTask(self: *Self) void {
            _ = self;
            runSmokeSuite();

            while (true) {
                const count = heartbeatCount();
                runAllocatorSmoke();
                runThreadAndChannelSmoke();
                runNetSmoke();
                runWifiStaSmoke();
                log.info("AP heartbeat {}", .{count});
                grt.time.sleepNanos(@intCast(5 * grt.time.duration.Second));
            }
        }
    };
}
