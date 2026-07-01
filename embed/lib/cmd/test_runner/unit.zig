const glib = @import("glib");

const cmd = @import("../../cmd.zig");

pub fn make(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn parserSplitsCommandAndArgs() !void {
            const parsed = cmd.Parser.parseLine("  stats  --json now  \n").?;
            try grt.std.testing.expectEqualStrings("stats", parsed.name);
            try grt.std.testing.expectEqualStrings("--json now", parsed.args);
            try grt.std.testing.expect(cmd.Parser.parseLine(" \t\r\n") == null);
        }

        fn registryExecutesRegisteredCommand() !void {
            var registry = cmd.Executor.Registry.init(grt.std.testing.allocator);
            defer registry.deinit();

            try registry.addCommand(.{
                .name = "echo",
                .handler = echo,
            });

            var buffer = BufferOutput{};
            const out = cmd.Output.make(BufferOutput).init(&buffer);
            try registry.executor().execute("echo hello world", out);
            try grt.std.testing.expectEqualStrings("hello world\n", buffer.bytes());
        }

        fn registryRejectsUnknownAndDuplicateCommands() !void {
            var registry = cmd.Executor.Registry.init(grt.std.testing.allocator);
            defer registry.deinit();

            try registry.addCommand(.{
                .name = "ping",
                .handler = echo,
            });
            try grt.std.testing.expectError(error.DuplicateCommand, registry.addCommand(.{
                .name = "ping",
                .handler = echo,
            }));

            var buffer = BufferOutput{};
            const out = cmd.Output.make(BufferOutput).init(&buffer);
            try grt.std.testing.expectError(error.UnknownCommand, registry.executor().execute("missing", out));
        }

        fn commonCommandsAreDeterministic() !void {
            var registry = cmd.Executor.Registry.init(grt.std.testing.allocator);
            defer registry.deinit();
            try cmd.common.registerMinimal(&registry, .{ .version = "test-version" });

            var buffer = BufferOutput{};
            const out = cmd.Output.make(BufferOutput).init(&buffer);
            try registry.executor().execute("ping", out);
            try grt.std.testing.expectEqualStrings("pong\n", buffer.bytes());

            buffer.clear();
            try registry.executor().execute("version", out);
            try grt.std.testing.expectEqualStrings("test-version\n", buffer.bytes());

            buffer.clear();
            try registry.executor().execute("help", out);
            try grt.std.testing.expect(glib.std.mem.indexOf(u8, buffer.bytes(), "ping - check command liveness\n") != null);
        }

        fn minimalCommandVersionBelongsToRegistry() !void {
            var first = cmd.Executor.Registry.init(grt.std.testing.allocator);
            defer first.deinit();
            var second = cmd.Executor.Registry.init(grt.std.testing.allocator);
            defer second.deinit();

            try cmd.common.registerMinimal(&first, .{ .version = "first" });
            try cmd.common.registerMinimal(&second, .{ .version = "second" });

            var buffer = BufferOutput{};
            const out = cmd.Output.make(BufferOutput).init(&buffer);

            try first.executor().execute("version", out);
            try grt.std.testing.expectEqualStrings("first\n", buffer.bytes());

            buffer.clear();
            try second.executor().execute("version", out);
            try grt.std.testing.expectEqualStrings("second\n", buffer.bytes());
        }

        fn adaptersWriteErrorsToOutput() !void {
            var registry = cmd.Executor.Registry.init(grt.std.testing.allocator);
            defer registry.deinit();

            var buffer = BufferOutput{};
            const out = cmd.Output.make(BufferOutput).init(&buffer);
            try cmd.uart.executeLine(registry.executor(), "missing", out);
            try grt.std.testing.expectEqualStrings("error: UnknownCommand\n", buffer.bytes());
        }

        fn desktopTcpDefaultsAreStable() !void {
            try grt.std.testing.expectEqualStrings("127.0.0.1", cmd.desktop_tcp.default_addr);
            try grt.std.testing.expectEqual(@as(u16, 39074), cmd.desktop_tcp.default_port);
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            TestCase.parserSplitsCommandAndArgs() catch |err| return fail(t, err);
            TestCase.registryExecutesRegisteredCommand() catch |err| return fail(t, err);
            TestCase.registryRejectsUnknownAndDuplicateCommands() catch |err| return fail(t, err);
            TestCase.commonCommandsAreDeterministic() catch |err| return fail(t, err);
            TestCase.minimalCommandVersionBelongsToRegistry() catch |err| return fail(t, err);
            TestCase.adaptersWriteErrorsToOutput() catch |err| return fail(t, err);
            TestCase.desktopTcpDefaultsAreStable() catch |err| return fail(t, err);
            return true;
        }

        pub fn deinit(self: *@This(), allocator: glib.std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }

        fn fail(t: *glib.testing.T, err: anyerror) bool {
            t.logFatal(@errorName(err));
            return false;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return glib.testing.TestRunner.make(Runner).new(&Holder.runner);
}

fn echo(_: ?*anyopaque, args: []const u8, out: cmd.Output) !void {
    try out.writeAll(args);
    try out.writeAll("\n");
}

const BufferOutput = struct {
    data: [512]u8 = undefined,
    len: usize = 0,

    pub fn write(self: *BufferOutput, chunk: []const u8) !usize {
        if (self.len + chunk.len > self.data.len) return error.BufferTooSmall;
        @memcpy(self.data[self.len..][0..chunk.len], chunk);
        self.len += chunk.len;
        return chunk.len;
    }

    pub fn bytes(self: *const BufferOutput) []const u8 {
        return self.data[0..self.len];
    }

    pub fn clear(self: *BufferOutput) void {
        self.len = 0;
    }
};
