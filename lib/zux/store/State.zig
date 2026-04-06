const testing_api = @import("testing");
const Subscriber = @import("Subscriber.zig");

pub fn make(comptime lib: type, comptime state_config: anytype, comptime HandlerFn: type) type {
    const AtomicBool = lib.atomic.Value(bool);
    const Config = @TypeOf(state_config);
    const info = @typeInfo(Config);
    if (info != .@"struct") {
        @compileError("zux.store.Builder.make expects configured state nodes to be struct literals");
    }

    const ArrayList = lib.ArrayList(HandlerFn);
    const NodeSubscriber = makeNodeSubscriber(lib);
    const fields_info = info.@"struct".fields;

    comptime var field_count: usize = 5;
    inline for (fields_info) |field| {
        if (comptimeEql(field.name, "stores")) continue;
        field_count += 1;
    }

    var fields: [field_count]lib.builtin.Type.StructField = undefined;
    fields[0] = .{
        .name = "dirty",
        .type = AtomicBool,
        .default_value_ptr = null,
        .is_comptime = false,
        .alignment = @alignOf(AtomicBool),
    };
    fields[1] = .{
        .name = "handlers",
        .type = ArrayList,
        .default_value_ptr = null,
        .is_comptime = false,
        .alignment = @alignOf(ArrayList),
    };
    fields[2] = .{
        .name = "subscriber_impl",
        .type = NodeSubscriber,
        .default_value_ptr = null,
        .is_comptime = false,
        .alignment = @alignOf(NodeSubscriber),
    };
    fields[3] = .{
        .name = "subscriber",
        .type = Subscriber,
        .default_value_ptr = null,
        .is_comptime = false,
        .alignment = @alignOf(Subscriber),
    };
    fields[4] = .{
        .name = "ticking",
        .type = bool,
        .default_value_ptr = null,
        .is_comptime = false,
        .alignment = @alignOf(bool),
    };

    comptime var i: usize = 5;
    inline for (fields_info) |field| {
        if (comptimeEql(field.name, "stores")) continue;

        const ChildType = make(lib, @field(state_config, field.name), HandlerFn);
        fields[i] = .{
            .name = field.name,
            .type = ChildType,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(ChildType),
        };
        i += 1;
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

pub fn init(comptime lib: type, comptime State: type, state: *State) void {
    initState(lib, State, state, null);
}

pub fn deinit(comptime lib: type, comptime State: type, allocator: lib.mem.Allocator, state: *State) void {
    deinitState(lib, State, allocator, state);
}

pub fn bindStores(comptime Stores: type, comptime node_config: anytype, stores: *Stores, state: anytype) error{OutOfMemory}!void {
    try bindStateStores(Stores, node_config, stores, state);
}

pub fn unbindStores(comptime Stores: type, comptime node_config: anytype, stores: *Stores, state: anytype) void {
    unbindStateStores(Stores, node_config, stores, state);
}

pub fn handlePath(
    comptime path: []const u8,
    allocator: anytype,
    state: anytype,
    handler: anytype,
) error{ OutOfMemory, InvalidPath }!void {
    try handleStatePath(path, allocator, state, handler);
}

pub fn unhandlePath(comptime path: []const u8, state: anytype, handler: anytype) bool {
    return unhandleStatePath(path, state, handler);
}

pub fn tick(comptime State: type, state: *State, stores: anytype) void {
    tickState(State, state, stores);
}

fn makeNodeSubscriber(comptime lib: type) type {
    const AtomicBool = lib.atomic.Value(bool);

    return struct {
        dirty: *AtomicBool,
        parent: ?*@This() = null,

        pub fn notify(self: *@This(), _: Subscriber.Notification) void {
            var current: ?*@This() = self;
            while (current) |node| : (current = node.parent) {
                node.dirty.store(true, .release);
            }
        }
    };
}

fn comptimeEql(comptime a: []const u8, comptime b: []const u8) bool {
    if (a.len != b.len) return false;
    inline for (a, 0..) |c, i| {
        if (c != b[i]) return false;
    }
    return true;
}

fn isMetaField(comptime name: []const u8) bool {
    return comptimeEql(name, "dirty") or
        comptimeEql(name, "handlers") or
        comptimeEql(name, "subscriber_impl") or
        comptimeEql(name, "subscriber") or
        comptimeEql(name, "ticking");
}

fn initState(
    comptime lib: type,
    comptime State: type,
    state: *State,
    parent: ?*makeNodeSubscriber(lib),
) void {
    const AtomicBool = lib.atomic.Value(bool);
    const fields = @typeInfo(State).@"struct".fields;

    state.dirty = AtomicBool.init(false);
    state.handlers = .empty;
    state.subscriber_impl = .{
        .dirty = &state.dirty,
        .parent = parent,
    };
    state.subscriber = Subscriber.init(&state.subscriber_impl);
    state.ticking = false;

    inline for (fields) |field| {
        if (comptime isMetaField(field.name)) {
            // Skip generated per-node metadata fields.
        } else {
            initState(lib, field.type, &@field(state.*, field.name), &state.subscriber_impl);
        }
    }
}

fn deinitState(comptime lib: type, comptime State: type, allocator: lib.mem.Allocator, state: *State) void {
    const fields = @typeInfo(State).@"struct".fields;

    state.handlers.deinit(allocator);

    inline for (fields) |field| {
        if (comptime isMetaField(field.name)) {
            // Skip generated per-node metadata fields.
        } else {
            deinitState(lib, field.type, allocator, &@field(state.*, field.name));
        }
    }
}

fn tickState(comptime State: type, state: *State, stores: anytype) void {
    const fields = @typeInfo(State).@"struct".fields;
    const was_dirty = state.dirty.swap(false, .acq_rel);
    if (!was_dirty) return;

    inline for (fields) |field| {
        if (comptime isMetaField(field.name)) {
            // Skip generated per-node metadata fields.
        } else {
            tickState(field.type, &@field(state.*, field.name), stores);
        }
    }

    state.ticking = true;
    defer state.ticking = false;
    for (state.handlers.items) |handler| {
        handler(stores);
    }
}

fn bindStateStores(comptime Stores: type, comptime node_config: anytype, stores: *Stores, state: anytype) error{OutOfMemory}!void {
    const NodeConfig = @TypeOf(node_config);
    const info = @typeInfo(NodeConfig);
    if (info != .@"struct") {
        @compileError("zux.store.Builder.make expects configured state nodes to be struct literals");
    }

    if (@hasField(NodeConfig, "stores")) {
        try bindStoreLabels(Stores, @field(node_config, "stores"), stores, state);
    }

    inline for (info.@"struct".fields) |field| {
        if (comptime comptimeEql(field.name, "stores")) {
            // Skip store label metadata field.
        } else {
            try bindStateStores(Stores, @field(node_config, field.name), stores, &@field(state.*, field.name));
        }
    }
}

fn bindStoreLabels(comptime Stores: type, comptime labels: anytype, stores: *Stores, state: anytype) error{OutOfMemory}!void {
    switch (@typeInfo(@TypeOf(labels))) {
        .pointer => |ptr| {
            switch (ptr.size) {
                .one => {
                    switch (@typeInfo(ptr.child)) {
                        .array => {
                            inline for (labels.*) |raw_label| {
                                const label = comptime labelText(raw_label);
                                if (!@hasField(Stores, label)) {
                                    @compileError("zux.store.Builder.make unknown store label '" ++ label ++ "'");
                                }
                                try @field(stores.*, label).subscribe(&state.subscriber);
                            }
                        },
                        .@"struct" => |struct_info| {
                            if (!struct_info.is_tuple) {
                                @compileError("zux.store.Builder.make expects state store labels to be an array, tuple, or pointer-to-array/tuple of labels");
                            }
                            inline for (struct_info.fields) |field| {
                                const label = comptime labelText(@field(labels.*, field.name));
                                if (!@hasField(Stores, label)) {
                                    @compileError("zux.store.Builder.make unknown store label '" ++ label ++ "'");
                                }
                                try @field(stores.*, label).subscribe(&state.subscriber);
                            }
                        },
                        else => {
                            @compileError("zux.store.Builder.make expects state store labels to be an array, tuple, or pointer-to-array/tuple of labels");
                        },
                    }
                },
                .slice => {
                    inline for (labels) |raw_label| {
                        const label = comptime labelText(raw_label);
                        if (!@hasField(Stores, label)) {
                            @compileError("zux.store.Builder.make unknown store label '" ++ label ++ "'");
                        }
                        try @field(stores.*, label).subscribe(&state.subscriber);
                    }
                },
                else => @compileError("zux.store.Builder.make expects state store labels to be an array, tuple, or pointer-to-array/tuple of labels"),
            }
        },
        .array => {
            inline for (labels) |raw_label| {
                const label = comptime labelText(raw_label);
                if (!@hasField(Stores, label)) {
                    @compileError("zux.store.Builder.make unknown store label '" ++ label ++ "'");
                }
                try @field(stores.*, label).subscribe(&state.subscriber);
            }
        },
        .@"struct" => |struct_info| {
            if (!struct_info.is_tuple) {
                @compileError("zux.store.Builder.make expects state store labels to be an array, tuple, or pointer-to-array/tuple of labels");
            }
            inline for (struct_info.fields) |field| {
                const label = comptime labelText(@field(labels, field.name));
                if (!@hasField(Stores, label)) {
                    @compileError("zux.store.Builder.make unknown store label '" ++ label ++ "'");
                }
                try @field(stores.*, label).subscribe(&state.subscriber);
            }
        },
        else => @compileError("zux.store.Builder.make expects state store labels to be an array, tuple, or pointer-to-array/tuple of labels"),
    }
}

fn unbindStateStores(comptime Stores: type, comptime node_config: anytype, stores: *Stores, state: anytype) void {
    const NodeConfig = @TypeOf(node_config);
    const info = @typeInfo(NodeConfig);
    if (info != .@"struct") {
        @compileError("zux.store.Builder.make expects configured state nodes to be struct literals");
    }

    if (@hasField(NodeConfig, "stores")) {
        unbindStoreLabels(Stores, @field(node_config, "stores"), stores, state);
    }

    inline for (info.@"struct".fields) |field| {
        if (comptime comptimeEql(field.name, "stores")) {
            // Skip store label metadata field.
        } else {
            unbindStateStores(Stores, @field(node_config, field.name), stores, &@field(state.*, field.name));
        }
    }
}

fn unbindStoreLabels(comptime Stores: type, comptime labels: anytype, stores: *Stores, state: anytype) void {
    switch (@typeInfo(@TypeOf(labels))) {
        .pointer => |ptr| {
            switch (ptr.size) {
                .one => {
                    switch (@typeInfo(ptr.child)) {
                        .array => {
                            inline for (labels.*) |raw_label| {
                                const label = comptime labelText(raw_label);
                                if (!@hasField(Stores, label)) {
                                    @compileError("zux.store.Builder.make unknown store label '" ++ label ++ "'");
                                }
                                _ = @field(stores.*, label).unsubscribe(&state.subscriber);
                            }
                        },
                        .@"struct" => |struct_info| {
                            if (!struct_info.is_tuple) {
                                @compileError("zux.store.Builder.make expects state store labels to be an array, tuple, or pointer-to-array/tuple of labels");
                            }
                            inline for (struct_info.fields) |field| {
                                const label = comptime labelText(@field(labels.*, field.name));
                                if (!@hasField(Stores, label)) {
                                    @compileError("zux.store.Builder.make unknown store label '" ++ label ++ "'");
                                }
                                _ = @field(stores.*, label).unsubscribe(&state.subscriber);
                            }
                        },
                        else => {
                            @compileError("zux.store.Builder.make expects state store labels to be an array, tuple, or pointer-to-array/tuple of labels");
                        },
                    }
                },
                .slice => {
                    inline for (labels) |raw_label| {
                        const label = comptime labelText(raw_label);
                        if (!@hasField(Stores, label)) {
                            @compileError("zux.store.Builder.make unknown store label '" ++ label ++ "'");
                        }
                        _ = @field(stores.*, label).unsubscribe(&state.subscriber);
                    }
                },
                else => @compileError("zux.store.Builder.make expects state store labels to be an array, tuple, or pointer-to-array/tuple of labels"),
            }
        },
        .array => {
            inline for (labels) |raw_label| {
                const label = comptime labelText(raw_label);
                if (!@hasField(Stores, label)) {
                    @compileError("zux.store.Builder.make unknown store label '" ++ label ++ "'");
                }
                _ = @field(stores.*, label).unsubscribe(&state.subscriber);
            }
        },
        .@"struct" => |struct_info| {
            if (!struct_info.is_tuple) {
                @compileError("zux.store.Builder.make expects state store labels to be an array, tuple, or pointer-to-array/tuple of labels");
            }
            inline for (struct_info.fields) |field| {
                const label = comptime labelText(@field(labels, field.name));
                if (!@hasField(Stores, label)) {
                    @compileError("zux.store.Builder.make unknown store label '" ++ label ++ "'");
                }
                _ = @field(stores.*, label).unsubscribe(&state.subscriber);
            }
        },
        else => @compileError("zux.store.Builder.make expects state store labels to be an array, tuple, or pointer-to-array/tuple of labels"),
    }
}

fn labelText(comptime raw_label: anytype) []const u8 {
    return switch (@typeInfo(@TypeOf(raw_label))) {
        .enum_literal => @tagName(raw_label),
        .pointer => |ptr| switch (ptr.size) {
            .slice => raw_label,
            .one => switch (@typeInfo(ptr.child)) {
                .array => raw_label[0..],
                else => @compileError("zux.store.Builder.make store labels must be enum literals or string literals"),
            },
            else => @compileError("zux.store.Builder.make store labels must be enum literals or string literals"),
        },
        .array => raw_label[0..],
        else => @compileError("zux.store.Builder.make store labels must be enum literals or string literals"),
    };
}

fn handleStatePath(
    comptime path: []const u8,
    allocator: anytype,
    state: anytype,
    handler: anytype,
) error{ OutOfMemory, InvalidPath }!void {
    const normalized = comptime trimPath(path);
    if (normalized.len == 0) {
        if (state.ticking) {
            @panic("zux.store.State.handlePath cannot mutate handlers during tick dispatch");
        }
        for (state.handlers.items) |existing| {
            if (existing == handler) return;
        }
        try state.handlers.append(allocator, handler);
        return;
    }

    const part = comptime splitPathHead(normalized);
    const State = @TypeOf(state.*);
    if (!@hasField(State, part.head) or comptime isMetaField(part.head)) {
        return error.InvalidPath;
    }

    try handleStatePath(part.tail, allocator, &@field(state.*, part.head), handler);
}

fn unhandleStatePath(comptime path: []const u8, state: anytype, handler: anytype) bool {
    const normalized = comptime trimPath(path);
    if (normalized.len == 0) {
        if (state.ticking) {
            @panic("zux.store.State.unhandlePath cannot mutate handlers during tick dispatch");
        }
        for (state.handlers.items, 0..) |existing, i| {
            if (existing != handler) continue;
            _ = state.handlers.orderedRemove(i);
            return true;
        }
        return false;
    }

    const part = comptime splitPathHead(normalized);
    const State = @TypeOf(state.*);
    if (!@hasField(State, part.head) or comptime isMetaField(part.head)) {
        return false;
    }

    return unhandleStatePath(part.tail, &@field(state.*, part.head), handler);
}

fn trimPath(comptime path: []const u8) []const u8 {
    var start: usize = 0;
    while (start < path.len and path[start] == '/') : (start += 1) {}

    var end = path.len;
    while (end > start and path[end - 1] == '/') : (end -= 1) {}

    return path[start..end];
}

fn splitPathHead(comptime path: []const u8) struct {
    head: []const u8,
    tail: []const u8,
} {
    inline for (path, 0..) |c, i| {
        if (c == '/') {
            return .{
                .head = path[0..i],
                .tail = path[i + 1 ..],
            };
        }
    }

    return .{
        .head = path,
        .tail = "",
    };
}

pub fn TestRunner(comptime lib: type) testing_api.TestRunner {
    const TestCase = struct {
        fn builds_tree_shape(testing: anytype, _: lib.mem.Allocator) !void {
            const HandlerFn = *const fn (stores: *struct {}) void;
            const StoreLib = struct {
                pub const builtin = lib.builtin;
                pub const atomic = lib.atomic;
                pub const ArrayList = lib.ArrayList;
            };

            const StateTy = make(StoreLib, .{
                .ui = .{
                    .stores = &.{ .wifi, .cellular },
                    .home = .{
                        .stores = &.{.wifi},
                    },
                },
                .device = .{
                    .stores = &.{.wifi},
                },
            }, HandlerFn);

            try testing.expect(@hasField(StateTy, "dirty"));
            try testing.expect(@hasField(StateTy, "handlers"));
            try testing.expect(@hasField(StateTy, "subscriber_impl"));
            try testing.expect(@hasField(StateTy, "subscriber"));
            try testing.expect(@hasField(StateTy, "ui"));
            try testing.expect(@hasField(StateTy, "device"));
            try testing.expect(!@hasField(StateTy, "stores"));

            const Ui = @FieldType(StateTy, "ui");
            try testing.expect(@hasField(Ui, "dirty"));
            try testing.expect(@hasField(Ui, "handlers"));
            try testing.expect(@hasField(Ui, "subscriber_impl"));
            try testing.expect(@hasField(Ui, "subscriber"));
            try testing.expect(@hasField(Ui, "home"));
            try testing.expect(!@hasField(Ui, "stores"));
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: lib.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *testing_api.T, allocator: lib.mem.Allocator) bool {
            _ = self;
            const testing = lib.testing;

            TestCase.builds_tree_shape(testing, allocator) catch |err| {
                t.logFatal(@errorName(err));
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
