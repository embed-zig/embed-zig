pub const default_max_handlers: usize = 64;
pub const default_max_segments: usize = 16;

const TaskOptions = @import("Options.zig");
const TaskRoutine = @import("Routine.zig");

const handler_index_field = "__task_handler_index";
const none: usize = ~@as(usize, 0);

pub const BuilderOptions = struct {
    max_handlers: usize = default_max_handlers,
    max_segments: usize = default_max_segments,
};

const ValidationError = error{
    EmptySegment,
    InvalidSegment,
    DuplicatePath,
    ReservedSegment,
    MaxHandlersExceeded,
    MaxSegmentsExceeded,
};

pub fn Builder() BuilderWithOptions(.{}) {
    return BuilderWithOptions(.{}).init();
}

pub fn BuilderWithOptions(comptime options: BuilderOptions) type {
    comptime {
        if (options.max_handlers == 0) {
            @compileError("task.Builder max_handlers must be > 0");
        }
        if (options.max_segments == 0) {
            @compileError("task.Builder max_segments must be > 0");
        }
    }

    return struct {
        const Self = @This();
        const Binding = struct {
            path: []const u8,
            Handler: type,
        };

        bindings: [options.max_handlers]Binding = undefined,
        binding_count: usize = 0,
        ErrorHandler: type = DefaultErrorHandler,

        pub fn init() Self {
            return .{};
        }

        pub fn handle(self: *Self, comptime path: []const u8, comptime Handler: type) void {
            const normalized = normalizePath(path, options.max_segments) catch |err|
                @compileError(validationErrorMessage(err));
            if (self.find(normalized) != null) {
                @compileError(validationErrorMessage(error.DuplicatePath));
            }
            if (self.binding_count >= options.max_handlers) {
                @compileError(validationErrorMessage(error.MaxHandlersExceeded));
            }
            if (!@hasDecl(Handler, "go")) {
                @compileError("task.Builder.handle Handler must expose go(name, options, routine)");
            }
            if (!@hasDecl(Handler, "currentToken")) {
                @compileError("task.Builder.handle Handler must expose currentToken() usize");
            }
            _ = handlerHandle(Handler);
            _ = handlerSpawnError(Handler);
            _ = @as(*const fn () usize, &Handler.currentToken);

            self.bindings[self.binding_count] = .{
                .path = normalized,
                .Handler = Handler,
            };
            self.binding_count += 1;
        }

        pub fn onError(self: *Self, comptime ErrorHandler: type) void {
            if (!@hasDecl(ErrorHandler, "onError")) {
                @compileError("task.Builder.onError handler must expose onError(name, err)");
            }
            self.ErrorHandler = ErrorHandler;
        }

        pub fn make(comptime self: Self) type {
            validateHandlers(self);
            const Tree = TreeType(self, "");
            const GeneratedHandle = handlerHandle(self.bindings[0].Handler);
            const HandlerSpawnError = handlerSpawnError(self.bindings[0].Handler);
            const GeneratedSpawnError = error{UnknownTask} || HandlerSpawnError;
            const ErrorHandler = self.ErrorHandler;

            return struct {
                pub const Handle = GeneratedHandle;
                pub const Options = TaskOptions;
                pub const Routine = TaskRoutine;
                pub const SpawnError = GeneratedSpawnError;
                pub const on_error = ErrorHandler;
                pub const handler_count = self.binding_count;
                pub const tree = Tree;

                pub fn currentToken() usize {
                    return self.bindings[0].Handler.currentToken();
                }

                pub fn go(name: []const u8, launch_options: TaskOptions, routine: TaskRoutine) SpawnError!Handle {
                    const idx = route(Tree, name) orelse return error.UnknownTask;
                    inline for (0..self.binding_count) |i| {
                        if (idx == i) {
                            return self.bindings[i].Handler.go(name, launch_options, routine);
                        }
                    }
                    unreachable;
                }
            };
        }

        fn find(comptime self: Self, comptime path: []const u8) ?usize {
            inline for (0..self.binding_count) |i| {
                if (comptimeEql(self.bindings[i].path, path)) return i;
            }
            return null;
        }
    };
}

const DefaultErrorHandler = struct {
    pub fn onError(_: []const u8, _: anyerror) void {
        @panic("task.go failed");
    }
};

fn validateHandlers(comptime builder: anytype) void {
    if (builder.binding_count == 0) {
        @compileError("task.Builder.make requires at least one handler");
    }

    const Handle = handlerHandle(builder.bindings[0].Handler);
    const SpawnError = handlerSpawnError(builder.bindings[0].Handler);

    inline for (1..builder.binding_count) |i| {
        const Handler = builder.bindings[i].Handler;
        if (handlerHandle(Handler) != Handle) {
            @compileError("task.Builder.make requires all handlers to use the same Handle");
        }
        if (handlerSpawnError(Handler) != SpawnError) {
            @compileError("task.Builder.make requires all handlers to use the same SpawnError");
        }
    }
}

fn handlerHandle(comptime Handler: type) type {
    if (!@hasDecl(Handler, "Handle")) {
        @compileError("task handler must expose pub const Handle");
    }
    const Handle = Handler.Handle;
    if (!@hasDecl(Handle, "join")) {
        @compileError("task handler Handle must expose join(self) void");
    }
    return Handle;
}

fn handlerSpawnError(comptime Handler: type) type {
    if (!@hasDecl(Handler, "SpawnError")) {
        @compileError("task handler must expose pub const SpawnError");
    }
    return Handler.SpawnError;
}

fn TreeType(comptime builder: anytype, comptime prefix: []const u8) type {
    const StructField = @TypeOf(@typeInfo(struct { field: usize }).@"struct".fields[0]);
    const handler_index = builder.find(prefix) orelse none;
    const default_handler_index = handler_index;

    comptime var children: [builder.binding_count][]const u8 = undefined;
    comptime var child_count: usize = 0;
    collectChildSegments(builder, prefix, &children, &child_count);

    var fields: [child_count + 1]StructField = undefined;
    fields[0] = .{
        .name = sentinelName(handler_index_field),
        .type = usize,
        .default_value_ptr = @ptrCast(&default_handler_index),
        .is_comptime = true,
        .alignment = @alignOf(usize),
    };

    inline for (0..child_count) |i| {
        const segment = children[i];
        const child_path = if (prefix.len == 0) segment else prefix ++ "/" ++ segment;
        const ChildType = TreeType(builder, child_path);
        fields[i + 1] = .{
            .name = sentinelName(segment),
            .type = ChildType,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(ChildType),
        };
    }

    return @Type(.{
        .@"struct" = .{
            .layout = .auto,
            .fields = &fields,
            .decls = &.{},
            .is_tuple = false,
        },
    });
}

fn collectChildSegments(
    comptime builder: anytype,
    comptime prefix: []const u8,
    comptime out: *[builder.binding_count][]const u8,
    comptime out_len: *usize,
) void {
    inline for (0..builder.binding_count) |i| {
        const path = builder.bindings[i].path;
        const rest = descendantRest(prefix, path) orelse continue;
        if (rest.len == 0) continue;

        const segment = firstSegment(rest);
        if (!contains(out, out_len.*, segment)) {
            out[out_len.*] = segment;
            out_len.* += 1;
        }
    }
}

fn descendantRest(comptime prefix: []const u8, comptime path: []const u8) ?[]const u8 {
    if (prefix.len == 0) return path;
    if (path.len <= prefix.len) return null;
    if (!comptimeEql(path[0..prefix.len], prefix)) return null;
    if (path[prefix.len] != '/') return null;
    return path[prefix.len + 1 ..];
}

fn firstSegment(comptime path: []const u8) []const u8 {
    inline for (path, 0..) |c, i| {
        if (c == '/') return path[0..i];
    }
    return path;
}

fn contains(comptime values: anytype, comptime len: usize, comptime value: []const u8) bool {
    inline for (0..len) |i| {
        if (comptimeEql(values[i], value)) return true;
    }
    return false;
}

fn route(comptime Node: type, name: []const u8) ?usize {
    const start = skipLeadingSlashes(name);
    return routeNode(Node, name[start..], handlerIndex(Node));
}

fn routeNode(comptime Node: type, rest: []const u8, best: ?usize) ?usize {
    if (rest.len == 0) return best;

    const segment_len = segmentLen(rest);
    if (segment_len == 0) return null;
    const segment = rest[0..segment_len];
    const tail = if (segment_len < rest.len) rest[segment_len + 1 ..] else rest[rest.len..];

    const info = @typeInfo(Node);
    inline for (info.@"struct".fields) |field| {
        if (comptime comptimeEql(field.name, handler_index_field)) continue;
        if (runtimeEql(field.name, segment)) {
            const next_best = handlerIndex(field.type) orelse best;
            return routeNode(field.type, tail, next_best);
        }
    }

    return best;
}

fn handlerIndex(comptime Node: type) ?usize {
    const info = @typeInfo(Node);
    inline for (info.@"struct".fields) |field| {
        if (comptimeEql(field.name, handler_index_field)) {
            const ptr = field.default_value_ptr orelse return null;
            const index_ptr: *const usize = @ptrCast(@alignCast(ptr));
            return if (index_ptr.* == none) null else index_ptr.*;
        }
    }
    return null;
}

fn skipLeadingSlashes(name: []const u8) usize {
    var i: usize = 0;
    while (i < name.len and name[i] == '/') : (i += 1) {}
    return i;
}

fn segmentLen(rest: []const u8) usize {
    var i: usize = 0;
    while (i < rest.len and rest[i] != '/') : (i += 1) {}
    return i;
}

fn normalizePath(comptime path: []const u8, comptime max_segments: usize) ValidationError![]const u8 {
    var start: usize = 0;
    var end: usize = path.len;

    while (start < end and path[start] == '/') : (start += 1) {}
    while (end > start and path[end - 1] == '/') : (end -= 1) {}

    const normalized = path[start..end];
    if (normalized.len == 0) return "";

    var segment_count: usize = 0;
    var segment_start: usize = 0;
    while (segment_start <= normalized.len) {
        var segment_end = segment_start;
        while (segment_end < normalized.len and normalized[segment_end] != '/') : (segment_end += 1) {}

        const segment = normalized[segment_start..segment_end];
        if (segment.len == 0) return error.EmptySegment;
        if (comptimeEql(segment, handler_index_field)) return error.ReservedSegment;
        if (!isIdentifierSegment(segment)) return error.InvalidSegment;

        segment_count += 1;
        if (segment_count > max_segments) return error.MaxSegmentsExceeded;
        if (segment_end == normalized.len) break;
        segment_start = segment_end + 1;
    }

    return normalized;
}

fn isIdentifierSegment(comptime segment: []const u8) bool {
    if (segment.len == 0) return false;
    if (!isIdentifierStart(segment[0])) return false;
    inline for (segment[1..]) |c| {
        if (!isIdentifierContinue(c)) return false;
    }
    return true;
}

fn isIdentifierStart(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or
        (c >= 'a' and c <= 'z') or
        c == '_';
}

fn isIdentifierContinue(c: u8) bool {
    return isIdentifierStart(c) or (c >= '0' and c <= '9');
}

fn validationErrorMessage(comptime err: ValidationError) []const u8 {
    return switch (err) {
        error.EmptySegment => "task.Builder.handle paths must not contain empty segments",
        error.InvalidSegment => "task.Builder.handle path segments must be Zig identifier-shaped",
        error.DuplicatePath => "task.Builder.handle found duplicate path",
        error.ReservedSegment => "task.Builder.handle path segment is reserved",
        error.MaxHandlersExceeded => "task.Builder exceeded max_handlers",
        error.MaxSegmentsExceeded => "task.Builder exceeded max_segments",
    };
}

fn sentinelName(comptime text: []const u8) [:0]const u8 {
    const terminated = text ++ "\x00";
    return terminated[0..text.len :0];
}

fn comptimeEql(comptime a: []const u8, comptime b: []const u8) bool {
    if (a.len != b.len) return false;
    inline for (a, 0..) |c, i| {
        if (c != b[i]) return false;
    }
    return true;
}

fn runtimeEql(comptime a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    inline for (a, 0..) |c, i| {
        if (c != b[i]) return false;
    }
    return true;
}

pub fn TestRunner(comptime lib: type) @import("testing").TestRunner {
    const testing_api = @import("testing");

    const TestCase = struct {
        const SpawnError = error{HandlerFailed};

        const State = struct {
            handler: []const u8 = "",
            name: []const u8 = "",
            run_count: usize = 0,
            join_count: usize = 0,
            min_stack_size: usize = 0,
        };

        const Handle = struct {
            state: *State,

            pub fn join(self: Handle) void {
                self.state.join_count += 1;
            }
        };

        fn Handler(comptime id: []const u8) type {
            const TestHandle = Handle;
            const TestSpawnError = SpawnError;

            return struct {
                pub const Handle = TestHandle;
                pub const SpawnError = TestSpawnError;

                pub fn go(name: []const u8, launch_options: TaskOptions, routine: TaskRoutine) TestSpawnError!TestHandle {
                    const state: *State = @ptrCast(@alignCast(routine.ptr));
                    state.handler = id;
                    state.name = name;
                    state.min_stack_size = launch_options.min_stack_size;
                    routine.run();
                    return .{ .state = state };
                }

                pub fn currentToken() usize {
                    return 42;
                }
            };
        }

        fn taskRun(state: *State) void {
            state.run_count += 1;
        }

        const ErrorHandler = struct {
            pub fn onError(name: []const u8, err: anyerror) void {
                _ = name;
                @panic(@errorName(err));
            }
        };

        fn makeTask() type {
            comptime var builder = Builder();
            builder.handle("", Handler("default"));
            builder.handle("ui/", Handler("ui"));
            builder.handle("ui/app/", Handler("ui_app"));
            builder.handle("audio/", Handler("audio"));
            builder.onError(ErrorHandler);
            return builder.make();
        }

        fn longestPrefixWins() !void {
            const Task = makeTask();
            var state: State = .{};
            const routine = TaskRoutine.init(&state, taskRun);

            const handle = try Task.go("ui/app/render", .{}, routine);
            handle.join();

            try lib.testing.expectEqualStrings("ui_app", state.handler);
            try lib.testing.expectEqualStrings("ui/app/render", state.name);
            try lib.testing.expectEqual(@as(usize, 1), state.run_count);
            try lib.testing.expectEqual(@as(usize, 1), state.join_count);
        }

        fn parentPrefixMatchesDescendant() !void {
            const Task = makeTask();
            var state: State = .{};
            const routine = TaskRoutine.init(&state, taskRun);

            const handle = try Task.go("ui/button", .{ .min_stack_size = 4096 }, routine);
            try lib.testing.expectEqualStrings("ui", state.handler);
            try lib.testing.expectEqual(@as(usize, 1), state.run_count);
            try lib.testing.expectEqual(@as(usize, 4096), state.min_stack_size);

            handle.join();
            try lib.testing.expectEqual(@as(usize, 1), state.join_count);
        }

        fn defaultHandlerMatchesUnknownName() !void {
            const Task = makeTask();
            var state: State = .{};
            const routine = TaskRoutine.init(&state, taskRun);

            const handle = try Task.go("wifi/main", .{}, routine);
            handle.join();

            try lib.testing.expectEqualStrings("default", state.handler);
            try lib.testing.expectEqual(@as(usize, 1), state.join_count);
        }

        fn unknownWithoutDefaultReturnsError() !void {
            const Task = comptime blk: {
                var builder = Builder();
                builder.handle("ui/", Handler("ui"));
                builder.onError(ErrorHandler);
                break :blk builder.make();
            };
            var state: State = .{};
            const routine = TaskRoutine.init(&state, taskRun);

            try lib.testing.expectError(error.UnknownTask, Task.go("wifi/main", .{}, routine));
        }

        fn exposesCurrentToken() !void {
            const Task = makeTask();
            try lib.testing.expectEqual(@as(usize, 42), Task.currentToken());
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            _ = allocator;

            TestCase.longestPrefixWins() catch |err| {
                t.logErrorf("task.Builder longest prefix failed: {}", .{err});
                return false;
            };
            TestCase.parentPrefixMatchesDescendant() catch |err| {
                t.logErrorf("task.Builder parent prefix failed: {}", .{err});
                return false;
            };
            TestCase.defaultHandlerMatchesUnknownName() catch |err| {
                t.logErrorf("task.Builder default handler failed: {}", .{err});
                return false;
            };
            TestCase.unknownWithoutDefaultReturnsError() catch |err| {
                t.logErrorf("task.Builder unknown task failed: {}", .{err});
                return false;
            };
            TestCase.exposesCurrentToken() catch |err| {
                t.logErrorf("task.Builder current token failed: {}", .{err});
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: lib.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return testing_api.TestRunner.make(Runner).new(&Holder.runner);
}
