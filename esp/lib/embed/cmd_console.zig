const embed_core = @import("embed_core");

const cmd = embed_core.cmd;

const ESP_OK = 0;
const ESP_ERR_INVALID_STATE = 0x103;

const EspConsoleConfig = extern struct {
    max_cmdline_length: usize,
    max_cmdline_args: usize,
    heap_alloc_caps: u32,
    hint_color: c_int,
    hint_bold: c_int,
};

const EspConsoleReplConfig = extern struct {
    max_history_len: u32,
    history_save_path: ?[*:0]const u8,
    task_stack_size: u32,
    task_priority: u32,
    task_core_id: c_int,
    prompt: ?[*:0]const u8,
    max_cmdline_length: usize,
};

const EspConsoleDevUsbSerialJtagConfig = extern struct {};

const EspConsoleRepl = opaque {};

const UsbSerialJtagDriverConfig = extern struct {
    tx_buffer_size: u32,
    rx_buffer_size: u32,
};

const EspConsoleCommand = extern struct {
    command: [*:0]const u8,
    help: ?[*:0]const u8,
    hint: ?[*:0]const u8,
    func: ?*const fn (argc: c_int, argv: [*][*:0]u8) callconv(.c) c_int,
    argtable: ?*anyopaque,
    func_w_context: ?*const fn (context: ?*anyopaque, argc: c_int, argv: [*][*:0]u8) callconv(.c) c_int,
    context: ?*anyopaque,
};

extern fn esp_console_init(config: *const EspConsoleConfig) c_int;
extern fn esp_console_cmd_register(command: *const EspConsoleCommand) c_int;
extern fn esp_console_new_repl_usb_serial_jtag(
    dev_config: *const EspConsoleDevUsbSerialJtagConfig,
    repl_config: *const EspConsoleReplConfig,
    ret_repl: *?*EspConsoleRepl,
) c_int;
extern fn esp_console_start_repl(repl: *EspConsoleRepl) c_int;
extern fn usb_serial_jtag_driver_install(config: *UsbSerialJtagDriverConfig) c_int;
extern fn usb_serial_jtag_vfs_use_driver() void;
extern fn xTaskCreatePinnedToCore(
    task: *const fn (?*anyopaque) callconv(.c) void,
    name: [*:0]const u8,
    stack_depth: u32,
    params: ?*anyopaque,
    priority: u32,
    task_handle: ?*?*anyopaque,
    core_id: c_int,
) c_int;
extern fn read(fd: c_int, buf: [*]u8, count: usize) isize;
extern fn printf(format: [*:0]const u8, ...) c_int;

var attached_executor: ?cmd.Executor = null;
var repl: ?*EspConsoleRepl = null;
var raw_task_started = false;

pub fn attach(executor: cmd.Executor) !void {
    if (attached_executor != null) return;
    attached_executor = executor;

    const console_config = EspConsoleConfig{
        .max_cmdline_length = 256,
        .max_cmdline_args = 32,
        .heap_alloc_caps = 0,
        .hint_color = 39,
        .hint_bold = 0,
    };
    const init_rc = esp_console_init(&console_config);
    if (init_rc != ESP_OK) return error.ConsoleInitFailed;

    try registerCommand("cmd", "execute an embed command line", cmdWrapper);
    try registerCommand("ping", "check command liveness", directCommand);
    try registerCommand("version", "print version", directCommand);
    try registerCommand("help", "list commands", directCommand);

    const dev_config = EspConsoleDevUsbSerialJtagConfig{};
    const repl_config = EspConsoleReplConfig{
        .max_history_len = 16,
        .history_save_path = null,
        .task_stack_size = 4096,
        .task_priority = 2,
        .task_core_id = -1,
        .prompt = "cmd> ",
        .max_cmdline_length = 256,
    };
    if (esp_console_new_repl_usb_serial_jtag(&dev_config, &repl_config, &repl) != ESP_OK) {
        try startRawLineTask();
        return;
    }
    if (repl) |handle| {
        if (esp_console_start_repl(handle) != ESP_OK) return error.ConsoleReplStartFailed;
    }
}

fn startRawLineTask() !void {
    if (raw_task_started) return;
    var usb_serial_config = UsbSerialJtagDriverConfig{
        .tx_buffer_size = 256,
        .rx_buffer_size = 256,
    };
    const install_rc = usb_serial_jtag_driver_install(&usb_serial_config);
    if (install_rc != ESP_OK and install_rc != ESP_ERR_INVALID_STATE) {
        return error.UsbSerialJtagDriverInstallFailed;
    }
    usb_serial_jtag_vfs_use_driver();

    const rc = xTaskCreatePinnedToCore(
        rawConsoleTask,
        "cmd_console",
        4096,
        null,
        2,
        null,
        0,
    );
    if (rc == 0) return error.ConsoleTaskCreateFailed;
    raw_task_started = true;
}

fn rawConsoleTask(_: ?*anyopaque) callconv(.c) void {
    var line: [256]u8 = undefined;
    var len: usize = 0;
    _ = printf("cmd> ");
    while (true) {
        var byte: [1]u8 = undefined;
        const n = read(0, &byte, 1);
        if (n <= 0) continue;
        switch (byte[0]) {
            '\r', '\n' => {
                if (len != 0) {
                    executeRawLine(line[0..len]);
                    len = 0;
                }
                _ = printf("cmd> ");
            },
            0x08, 0x7f => {
                if (len != 0) len -= 1;
            },
            else => {
                if (len < line.len) {
                    line[len] = byte[0];
                    len += 1;
                } else {
                    _ = printf("error: LineTooLong\ncmd> ");
                    len = 0;
                }
            },
        }
    }
}

fn executeRawLine(line: []const u8) void {
    const command_line = stripCmdPrefix(trimAscii(line));
    var output = PrintOutput{};
    const out = cmd.Output.make(PrintOutput).init(&output);
    attached_executor.?.execute(command_line, out) catch |err| {
        const name = @errorName(err);
        _ = printf("error: %.*s\n", @as(c_int, @intCast(name.len)), name.ptr);
    };
}

fn stripCmdPrefix(line: []const u8) []const u8 {
    if (line.len < 3) return line;
    if (!bytesEqual(line[0..3], "cmd")) return line;
    if (line.len == 3) return "";
    if (line[3] != ' ' and line[3] != '\t') return line;
    return trimAscii(line[4..]);
}

fn trimAscii(line: []const u8) []const u8 {
    var start: usize = 0;
    while (start < line.len and isSpace(line[start])) : (start += 1) {}
    var end = line.len;
    while (end > start and isSpace(line[end - 1])) : (end -= 1) {}
    return line[start..end];
}

fn isSpace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n';
}

fn bytesEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |actual, expected| {
        if (actual != expected) return false;
    }
    return true;
}

fn registerCommand(
    comptime name: [:0]const u8,
    comptime help: [:0]const u8,
    handler: *const fn (argc: c_int, argv: [*][*:0]u8) callconv(.c) c_int,
) !void {
    const command = EspConsoleCommand{
        .command = name,
        .help = help,
        .hint = null,
        .func = handler,
        .argtable = null,
        .func_w_context = null,
        .context = null,
    };
    if (esp_console_cmd_register(&command) != ESP_OK) return error.ConsoleCommandRegisterFailed;
}

fn cmdWrapper(argc: c_int, argv: [*][*:0]u8) callconv(.c) c_int {
    return executeArgv(1, argc, argv);
}

fn directCommand(argc: c_int, argv: [*][*:0]u8) callconv(.c) c_int {
    return executeArgv(0, argc, argv);
}

fn executeArgv(skip: c_int, argc: c_int, argv: [*][*:0]u8) c_int {
    var line: [256]u8 = undefined;
    const built = buildLine(&line, skip, argc, argv) catch {
        _ = printf("command line too long\n");
        return 1;
    };
    var output = PrintOutput{};
    const out = cmd.Output.make(PrintOutput).init(&output);
    attached_executor.?.execute(built, out) catch |err| {
        const name = @errorName(err);
        _ = printf("error: %.*s\n", @as(c_int, @intCast(name.len)), name.ptr);
        return 1;
    };
    return 0;
}

fn buildLine(out: []u8, skip: c_int, argc: c_int, argv: [*][*:0]u8) ![]const u8 {
    var len: usize = 0;
    var index: c_int = skip;
    while (index < argc) : (index += 1) {
        const arg = cString(argv[@intCast(index)]);
        if (len != 0) {
            if (len == out.len) return error.LineTooLong;
            out[len] = ' ';
            len += 1;
        }
        if (len + arg.len > out.len) return error.LineTooLong;
        @memcpy(out[len..][0..arg.len], arg);
        len += arg.len;
    }
    return out[0..len];
}

fn cString(value: [*:0]u8) []const u8 {
    var len: usize = 0;
    while (value[len] != 0) : (len += 1) {}
    return value[0..len];
}

const PrintOutput = struct {
    pub fn write(self: *PrintOutput, bytes: []const u8) !usize {
        _ = self;
        if (bytes.len == 0) return 0;
        _ = printf("%.*s", @as(c_int, @intCast(bytes.len)), bytes.ptr);
        return bytes.len;
    }
};
