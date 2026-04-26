const glib = @import("glib");
const StoreSubscriber = @import("Subscriber.zig");
const StoreState = @import("State.zig");
const StoreTypes = @import("Stores.zig");

pub const default_max_stores: usize = 64;
pub const default_max_state_nodes: usize = 256;
pub const default_max_store_refs: usize = 512;
pub const default_max_depth: usize = 32;

pub const BuilderOptions = struct {
    max_stores: usize = default_max_stores,
    max_state_nodes: usize = default_max_state_nodes,
    max_store_refs: usize = default_max_store_refs,
    max_depth: usize = default_max_depth,
};

const ValidationError = error{
    EmptyStoreLabel,
    EmptyStatePath,
    EmptyStatePathSegment,
    DotSeparatedStatePath,
    ReservedStateField,
    UnsupportedStoreLabel,
    UnsupportedStateLabels,
    UnknownStoreLabel,
    MaxStoresExceeded,
    MaxStateNodesExceeded,
    MaxStoreRefsExceeded,
    MaxDepthExceeded,
};

pub fn Builder(comptime options: BuilderOptions) type {
    comptime {
        if (options.max_stores == 0) {
            @compileError("zux.store.Builder max_stores must be > 0");
        }
        if (options.max_state_nodes == 0) {
            @compileError("zux.store.Builder max_state_nodes must be > 0");
        }
        if (options.max_store_refs == 0) {
            @compileError("zux.store.Builder max_store_refs must be > 0");
        }
        if (options.max_depth == 0) {
            @compileError("zux.store.Builder max_depth must be > 0");
        }
    }

    return struct {
        const Self = @This();
        const StoreBinding = struct {
            name: []const u8,
            StoreType: type,
        };
        const StateBinding = struct {
            path: []const u8,
            labels: [options.max_stores][]const u8 = undefined,
            labels_len: usize = 0,
        };

        store_bindings: [options.max_stores]StoreBinding = undefined,
        state_bindings: [options.max_state_nodes]StateBinding = undefined,
        store_count: usize = 0,
        state_binding_count: usize = 0,
        state_node_count: usize = 1,
        store_ref_count: usize = 0,

        pub fn init() Self {
            return .{};
        }

        // Set the store type for one `config.stores` field.
        // Repeated calls for the same label should overwrite the previous type.
        pub fn setStore(self: *Self, comptime label: anytype, comptime StoreType: type) void {
            const name = normalizeStoreLabel(label) catch |err| @compileError(validationErrorMessage(err));
            if (self.findStore(name)) |idx| {
                self.store_bindings[idx].StoreType = StoreType;
                return;
            }
            if (self.store_count >= options.max_stores) {
                @compileError(validationErrorMessage(error.MaxStoresExceeded));
            }
            self.store_bindings[self.store_count] = .{
                .name = name,
                .StoreType = StoreType,
            };
            self.store_count += 1;
        }

        // Set the store labels for one slash-delimited state node path,
        // implicitly creating any missing intermediate nodes.
        // Repeated calls for the same path should overwrite the previous labels.
        pub fn setState(self: *Self, comptime path: []const u8, comptime labels: anytype) void {
            const normalized_path = validateStatePath(path, options.max_depth) catch |err| @compileError(validationErrorMessage(err));

            var next: StateBinding = .{
                .path = normalized_path,
            };
            collectLabels(labels, &next.labels, &next.labels_len) catch |err| @compileError(validationErrorMessage(err));

            if (self.findState(normalized_path)) |idx| {
                self.state_bindings[idx] = next;
            } else {
                if (self.state_binding_count >= options.max_state_nodes) {
                    @compileError(validationErrorMessage(error.MaxStateNodesExceeded));
                }
                self.state_bindings[self.state_binding_count] = next;
                self.state_binding_count += 1;
            }

            self.state_node_count = countStateNodes(self.*);
            self.store_ref_count = countStoreRefs(self.*);
            validateBuilderCounts(self.*, options) catch |err| @compileError(validationErrorMessage(err));
        }

        pub fn make(comptime self: Self, comptime grt: type) type {
            validateBuilder(self, options) catch |err| @compileError(validationErrorMessage(err));

            const stores_config = makeStoresConfig(self);
            const state_config = makeStateNodeConfig(self, "");
            const Allocator = glib.std.mem.Allocator;

            return struct {
                const Generated = @This();

                pub const Lib = grt;
                pub const Stores = StoreTypes.make(grt, stores_config);
                pub const HandlerFn = *const fn (stores: *Stores) void;
                pub const State = StoreState.make(grt, state_config, HandlerFn);
                pub const HandleError = error{
                    OutOfMemory,
                    InvalidPath,
                };
                pub const SubscribePathError = error{
                    OutOfMemory,
                    InvalidPath,
                };

                allocator: Allocator,
                stores: Stores,
                state: *State,

                pub fn init(allocator: Allocator, stores: Stores) !Generated {
                    const state = try allocator.create(State);
                    StoreState.init(grt, State, state);

                    var self_store: Generated = .{
                        .allocator = allocator,
                        .stores = stores,
                        .state = state,
                    };
                    errdefer {
                        StoreState.unbindStores(Stores, state_config, &self_store.stores, self_store.state);
                        StoreState.deinit(grt, State, allocator, state);
                        allocator.destroy(state);
                    }

                    try StoreState.bindStores(Stores, state_config, &self_store.stores, self_store.state);
                    return self_store;
                }

                pub fn deinit(self_store: *Generated) void {
                    StoreState.unbindStores(Stores, state_config, &self_store.stores, self_store.state);
                    StoreState.deinit(grt, State, self_store.allocator, self_store.state);
                    self_store.allocator.destroy(self_store.state);
                }

                pub fn handle(self_store: *Generated, comptime path: []const u8, handler: HandlerFn) HandleError!void {
                    try StoreState.handlePath(path, self_store.allocator, self_store.state, handler);
                }

                pub fn unhandle(self_store: *Generated, comptime path: []const u8, handler: HandlerFn) bool {
                    return StoreState.unhandlePath(path, self_store.state, handler);
                }

                pub fn subscribePath(
                    self_store: *Generated,
                    comptime path: []const u8,
                    subscriber: *StoreSubscriber,
                ) SubscribePathError!void {
                    try StoreState.subscribePath(path, self_store.allocator, self_store.state, subscriber);
                }

                pub fn unsubscribePath(
                    self_store: *Generated,
                    comptime path: []const u8,
                    subscriber: *StoreSubscriber,
                ) bool {
                    return StoreState.unsubscribePath(path, self_store.state, subscriber);
                }

                pub fn tick(self_store: *Generated) void {
                    tickStores(&self_store.stores);
                    StoreState.tick(State, self_store.state, &self_store.stores);
                }

                fn tickStores(stores: *Stores) void {
                    inline for (@typeInfo(Stores).@"struct".fields) |field| {
                        if (@hasDecl(field.type, "tick")) {
                            @field(stores.*, field.name).tick();
                        }
                    }
                }
            };
        }

        fn findStore(self: Self, comptime name: []const u8) ?usize {
            inline for (0..self.store_count) |i| {
                if (comptimeEql(self.store_bindings[i].name, name)) return i;
            }
            return null;
        }

        fn findState(self: Self, comptime path: []const u8) ?usize {
            inline for (0..self.state_binding_count) |i| {
                if (comptimeEql(self.state_bindings[i].path, path)) return i;
            }
            return null;
        }
    };
}

fn validationErrorMessage(err: ValidationError) []const u8 {
    return switch (err) {
        error.EmptyStoreLabel => "zux.store.Builder store labels must not be empty",
        error.EmptyStatePath => "zux.store.Builder.setState paths must not be empty",
        error.EmptyStatePathSegment => "zux.store.Builder.setState paths must not contain empty segments",
        error.DotSeparatedStatePath => "zux.store.Builder.setState paths must use '/' separators instead of '.'",
        error.ReservedStateField => "zux.store.Builder.setState paths cannot use reserved state field names",
        error.UnsupportedStoreLabel => "zux.store.Builder.setStore labels must be enum literals or string literals",
        error.UnsupportedStateLabels => "zux.store.Builder.setState labels must be enum literals, string literals, or tuples/arrays of them",
        error.UnknownStoreLabel => "zux.store.Builder.make found state labels that do not match any configured store",
        error.MaxStoresExceeded => "zux.store.Builder exceeded max_stores",
        error.MaxStateNodesExceeded => "zux.store.Builder exceeded max_state_nodes",
        error.MaxStoreRefsExceeded => "zux.store.Builder exceeded max_store_refs",
        error.MaxDepthExceeded => "zux.store.Builder exceeded max_depth",
    };
}

fn normalizeStoreLabel(comptime raw_label: anytype) ValidationError![]const u8 {
    const label = labelText(raw_label) catch return error.UnsupportedStoreLabel;
    if (label.len == 0) return error.EmptyStoreLabel;
    return label;
}

fn labelText(comptime raw_label: anytype) ValidationError![]const u8 {
    return switch (@typeInfo(@TypeOf(raw_label))) {
        .enum_literal => @tagName(raw_label),
        .pointer => |ptr| switch (ptr.size) {
            .slice => raw_label,
            .one => switch (@typeInfo(ptr.child)) {
                .array => raw_label[0..],
                else => error.UnsupportedStateLabels,
            },
            else => error.UnsupportedStateLabels,
        },
        .array => raw_label[0..],
        else => error.UnsupportedStateLabels,
    };
}

fn sentinelName(comptime text: []const u8) [:0]const u8 {
    const terminated = text ++ "\x00";
    return terminated[0..text.len :0];
}

fn validateStatePath(comptime path: []const u8, comptime max_depth: usize) ValidationError![]const u8 {
    if (path.len == 0) return error.EmptyStatePath;
    if (path[0] == '/' or path[path.len - 1] == '/') return error.EmptyStatePathSegment;

    comptime var depth: usize = 1;
    comptime var segment_start: usize = 0;

    inline for (path, 0..) |c, i| {
        if (c == '.') {
            return error.DotSeparatedStatePath;
        }
        if (c == '/') {
            if (i == segment_start) return error.EmptyStatePathSegment;
            try validateStateSegment(path[segment_start..i]);
            depth += 1;
            if (depth > max_depth) return error.MaxDepthExceeded;
            segment_start = i + 1;
        }
    }

    try validateStateSegment(path[segment_start..]);
    return path;
}

fn validateStateSegment(comptime segment: []const u8) ValidationError!void {
    if (segment.len == 0) return error.EmptyStatePathSegment;
    if (isReservedStateField(segment)) return error.ReservedStateField;
}

fn isReservedStateField(comptime name: []const u8) bool {
    return comptimeEql(name, "stores") or
        comptimeEql(name, "dirty") or
        comptimeEql(name, "handlers") or
        comptimeEql(name, "subscriber_impl") or
        comptimeEql(name, "subscriber") or
        comptimeEql(name, "ticking");
}

fn comptimeEql(comptime a: []const u8, comptime b: []const u8) bool {
    if (a.len != b.len) return false;
    inline for (a, 0..) |c, i| {
        if (c != b[i]) return false;
    }
    return true;
}

fn appendUniqueLabel(
    comptime out: anytype,
    comptime len: *usize,
    comptime label: []const u8,
) ValidationError!void {
    inline for (0..len.*) |i| {
        if (comptimeEql(out[i], label)) return;
    }
    if (len.* >= out.len) return error.MaxStoresExceeded;
    out[len.*] = label;
    len.* += 1;
}

fn collectLabels(
    comptime labels: anytype,
    comptime out: anytype,
    comptime len: *usize,
) ValidationError!void {
    switch (@typeInfo(@TypeOf(labels))) {
        .enum_literal => try appendUniqueLabel(out, len, try labelText(labels)),
        .pointer => |ptr| switch (ptr.size) {
            .slice => {
                if (ptr.child == u8) {
                    try appendUniqueLabel(out, len, try labelText(labels));
                } else {
                    inline for (labels) |item| {
                        try collectLabels(item, out, len);
                    }
                }
            },
            .one => switch (@typeInfo(ptr.child)) {
                .array => |arr| {
                    if (arr.child == u8) {
                        try appendUniqueLabel(out, len, try labelText(labels));
                    } else {
                        inline for (labels.*) |item| {
                            try collectLabels(item, out, len);
                        }
                    }
                },
                .@"struct" => |info| {
                    if (!info.is_tuple) return error.UnsupportedStateLabels;
                    inline for (info.fields) |field| {
                        try collectLabels(@field(labels.*, field.name), out, len);
                    }
                },
                else => return error.UnsupportedStateLabels,
            },
            else => return error.UnsupportedStateLabels,
        },
        .array => |arr| {
            if (arr.child == u8) {
                try appendUniqueLabel(out, len, try labelText(labels));
            } else {
                inline for (labels) |item| {
                    try collectLabels(item, out, len);
                }
            }
        },
        .@"struct" => |info| {
            if (!info.is_tuple) return error.UnsupportedStateLabels;
            inline for (info.fields) |field| {
                try collectLabels(@field(labels, field.name), out, len);
            }
        },
        else => return error.UnsupportedStateLabels,
    }
}

fn countStoreRefs(comptime builder: anytype) usize {
    comptime var total: usize = 0;
    inline for (0..builder.state_binding_count) |i| {
        total += builder.state_bindings[i].labels_len;
    }
    return total;
}

fn countStateNodes(comptime builder: anytype) usize {
    comptime var prefixes: [builder.state_bindings.len][]const u8 = undefined;
    comptime var prefix_len: usize = 0;

    inline for (0..builder.state_binding_count) |i| {
        const path = builder.state_bindings[i].path;
        inline for (path, 0..) |c, idx| {
            if (c != '/') continue;
            appendUniqueString(&prefixes, &prefix_len, path[0..idx]);
        }
        appendUniqueString(&prefixes, &prefix_len, path);
    }

    return 1 + prefix_len;
}

fn appendUniqueString(
    comptime out: anytype,
    comptime len: *usize,
    comptime value: []const u8,
) void {
    inline for (0..len.*) |i| {
        if (comptimeEql(out.*[i], value)) return;
    }
    out.*[len.*] = value;
    len.* += 1;
}

fn validateBuilderCounts(comptime builder: anytype, comptime options: BuilderOptions) ValidationError!void {
    if (builder.store_count > options.max_stores) return error.MaxStoresExceeded;
    if (builder.state_node_count > options.max_state_nodes) return error.MaxStateNodesExceeded;
    if (builder.store_ref_count > options.max_store_refs) return error.MaxStoreRefsExceeded;
}

fn validateBuilder(comptime builder: anytype, comptime options: BuilderOptions) ValidationError!void {
    try validateBuilderCounts(builder, options);
    inline for (0..builder.state_binding_count) |i| {
        const binding = builder.state_bindings[i];
        inline for (0..binding.labels_len) |label_idx| {
            const label = binding.labels[label_idx];
            if (!hasStoreLabel(builder, label)) return error.UnknownStoreLabel;
        }
    }
}

fn hasStoreLabel(comptime builder: anytype, comptime label: []const u8) bool {
    inline for (0..builder.store_count) |i| {
        if (comptimeEql(builder.store_bindings[i].name, label)) return true;
    }
    return false;
}

fn makeStoresConfig(comptime builder: anytype) StoresConfigType(builder) {
    var config: StoresConfigType(builder) = undefined;
    inline for (0..builder.store_count) |i| {
        const binding = builder.store_bindings[i];
        @field(config, binding.name) = binding.StoreType;
    }
    return config;
}

fn StoresConfigType(comptime builder: anytype) type {
    var fields: [builder.store_count]glib.std.builtin.Type.StructField = undefined;

    inline for (0..builder.store_count) |i| {
        const binding = builder.store_bindings[i];
        fields[i] = .{
            .name = sentinelName(binding.name),
            .type = type,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(type),
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

fn makeStateNodeConfig(comptime builder: anytype, comptime prefix: []const u8) StateNodeConfigType(builder, prefix) {
    const Config = StateNodeConfigType(builder, prefix);
    var config: Config = undefined;

    if (labelsLenForPath(builder, prefix) > 0) {
        @field(config, "stores") = labelsArrayForPath(builder, prefix);
    }

    comptime var child_prefixes: [builder.state_node_count][]const u8 = undefined;
    comptime var child_count: usize = 0;
    collectChildPrefixes(builder, prefix, &child_prefixes, &child_count);

    inline for (0..child_count) |i| {
        const child_prefix = child_prefixes[i];
        @field(config, childFieldName(prefix, child_prefix)) = makeStateNodeConfig(builder, child_prefix);
    }

    return config;
}

fn StateNodeConfigType(comptime builder: anytype, comptime prefix: []const u8) type {
    const labels_len = labelsLenForPath(builder, prefix);

    comptime var child_prefixes: [builder.state_node_count][]const u8 = undefined;
    comptime var child_count: usize = 0;
    collectChildPrefixes(builder, prefix, &child_prefixes, &child_count);

    const field_count = child_count + @as(usize, if (labels_len > 0) 1 else 0);
    var fields: [field_count]glib.std.builtin.Type.StructField = undefined;
    comptime var field_index: usize = 0;

    if (labels_len > 0) {
        const Labels = [labels_len][]const u8;
        fields[field_index] = .{
            .name = sentinelName("stores"),
            .type = Labels,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(Labels),
        };
        field_index += 1;
    }

    inline for (0..child_count) |i| {
        const child_prefix = child_prefixes[i];
        const ChildType = StateNodeConfigType(builder, child_prefix);
        fields[field_index] = .{
            .name = sentinelName(childFieldName(prefix, child_prefix)),
            .type = ChildType,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(ChildType),
        };
        field_index += 1;
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

fn labelsLenForPath(comptime builder: anytype, comptime prefix: []const u8) usize {
    if (findStateBindingIndex(builder, prefix)) |idx| {
        return builder.state_bindings[idx].labels_len;
    }
    return 0;
}

fn labelsArrayForPath(comptime builder: anytype, comptime prefix: []const u8) [labelsLenForPath(builder, prefix)][]const u8 {
    const idx = findStateBindingIndex(builder, prefix).?;
    const binding = builder.state_bindings[idx];
    var labels: [binding.labels_len][]const u8 = undefined;
    inline for (0..binding.labels_len) |i| {
        labels[i] = binding.labels[i];
    }
    return labels;
}

fn findStateBindingIndex(comptime builder: anytype, comptime path: []const u8) ?usize {
    inline for (0..builder.state_binding_count) |i| {
        if (comptimeEql(builder.state_bindings[i].path, path)) return i;
    }
    return null;
}

fn collectChildPrefixes(
    comptime builder: anytype,
    comptime prefix: []const u8,
    comptime out: anytype,
    comptime len: *usize,
) void {
    inline for (0..builder.state_binding_count) |i| {
        const binding = builder.state_bindings[i];
        const child_prefix = immediateChildPrefix(binding.path, prefix) orelse continue;
        appendUniqueString(out, len, child_prefix);
    }
}

fn immediateChildPrefix(comptime path: []const u8, comptime prefix: []const u8) ?[]const u8 {
    if (prefix.len == 0) {
        const end = firstPathSeparatorIndex(path) orelse path.len;
        return path[0..end];
    }
    if (!startsWith(path, prefix)) return null;
    if (path.len <= prefix.len) return null;
    if (path[prefix.len] != '/') return null;

    const rest_start = prefix.len + 1;
    const rest = path[rest_start..];
    const rel_end = firstPathSeparatorIndex(rest) orelse rest.len;
    return path[0 .. rest_start + rel_end];
}

fn childFieldName(comptime prefix: []const u8, comptime child_prefix: []const u8) []const u8 {
    if (prefix.len == 0) return child_prefix;
    return child_prefix[prefix.len + 1 ..];
}

fn startsWith(comptime text: []const u8, comptime prefix: []const u8) bool {
    if (prefix.len > text.len) return false;
    return comptimeEql(text[0..prefix.len], prefix);
}

fn firstPathSeparatorIndex(comptime text: []const u8) ?usize {
    inline for (text, 0..) |c, i| {
        if (c == '/') return i;
    }
    return null;
}

pub fn TestRunner(comptime grt: type) glib.testing.TestRunner {
    const TestCase = struct {
        fn set_store_and_state_tracks_counts_and_overwrites(_: glib.std.mem.Allocator) !void {
            const B = Builder(.{});
            const Wifi = struct {};
            const Cellular = struct {};
            const Wifi2 = struct {
                enabled: bool = false,
            };

            const builder = comptime blk: {
                var next = B.init();
                next.setStore(.wifi, Wifi);
                next.setStore(.cellular, Cellular);
                next.setState("ui/home", .{ .wifi, .cellular });
                next.setState("ui", .{.wifi});
                next.setState("ui/home", .{.wifi});
                next.setStore(.wifi, Wifi2);
                break :blk next;
            };

            try grt.std.testing.expectEqual(@as(usize, 2), builder.store_count);
            try grt.std.testing.expectEqual(@as(usize, 3), builder.state_node_count);
            try grt.std.testing.expectEqual(@as(usize, 2), builder.store_ref_count);
            const wifi_index = comptime builder.findStore("wifi").?;
            try grt.std.testing.expect(builder.store_bindings[wifi_index].StoreType == Wifi2);
        }

        fn validate_state_path_reports_errors(_: glib.std.mem.Allocator) !void {
            try grt.std.testing.expectError(error.EmptyStatePath, validateStatePath("", 4));
            try grt.std.testing.expectError(error.DotSeparatedStatePath, validateStatePath(".ui", 4));
            try grt.std.testing.expectError(error.DotSeparatedStatePath, validateStatePath("ui..home", 4));
            try grt.std.testing.expectError(error.DotSeparatedStatePath, validateStatePath("ui.home", 4));
            try grt.std.testing.expectEqualStrings("ui/home", try validateStatePath("ui/home", 4));
            try grt.std.testing.expectError(error.ReservedStateField, validateStatePath("ui/stores", 4));
            try grt.std.testing.expectError(error.MaxDepthExceeded, validateStatePath("a/b/c", 2));
        }

        fn collect_labels_accepts_singles_tuples_and_dedupes(_: glib.std.mem.Allocator) !void {
            const result = comptime blk: {
                var labels: [4][]const u8 = undefined;
                var len: usize = 0;
                try collectLabels(.{ .wifi, "cellular", .wifi }, &labels, &len);
                break :blk .{
                    .labels = labels,
                    .len = len,
                };
            };

            try grt.std.testing.expectEqual(@as(usize, 2), result.len);
            try grt.std.testing.expectEqualStrings("wifi", result.labels[0]);
            try grt.std.testing.expectEqualStrings("cellular", result.labels[1]);
        }

        fn make_builds_generated_store_type(allocator: glib.std.mem.Allocator) !void {
            const B = Builder(.{});

            const Wifi = struct { value: u32 };
            const Cellular = struct { enabled: bool };

            const AppStore = comptime blk: {
                var builder = B.init();
                builder.setStore(.wifi, Wifi);
                builder.setStore(.cellular, Cellular);
                builder.setState("ui", .{});
                builder.setState("ui/home", .{});
                break :blk builder.make(grt);
            };

            try grt.std.testing.expect(@hasField(AppStore.Stores, "wifi"));
            try grt.std.testing.expect(@hasField(AppStore.Stores, "cellular"));
            try grt.std.testing.expect(@hasField(AppStore.State, "ui"));
            try grt.std.testing.expect(@hasField(@FieldType(AppStore.State, "ui"), "home"));

            var store = try AppStore.init(allocator, .{
                .wifi = .{ .value = 1 },
                .cellular = .{ .enabled = true },
            });
            defer store.deinit();

            try grt.std.testing.expectEqual(@as(u32, 1), store.stores.wifi.value);
            try grt.std.testing.expect(store.stores.cellular.enabled);
        }

        fn make_allows_state_before_store_when_labels_resolve(_: glib.std.mem.Allocator) !void {
            const B = Builder(.{});

            const Wifi = struct { value: u32 };

            const AppStore = comptime blk: {
                var builder = B.init();
                builder.setState("ui/home", .{.wifi});
                builder.setStore(.wifi, Wifi);
                break :blk builder.make(grt);
            };

            try grt.std.testing.expect(@hasField(AppStore.State, "ui"));
            try grt.std.testing.expect(@hasField(@FieldType(AppStore.State, "ui"), "home"));
        }

        fn validate_builder_reports_unknown_store_label(_: glib.std.mem.Allocator) !void {
            const B = Builder(.{});

            const result = comptime blk: {
                var builder = B.init();
                builder.setState("ui", .{.wifi});
                break :blk validateBuilder(builder, .{});
            };

            try grt.std.testing.expectError(error.UnknownStoreLabel, result);
        }

        fn validate_builder_counts_reports_capacity_errors(_: glib.std.mem.Allocator) !void {
            const store_limit = comptime validateBuilderCounts(.{
                .store_count = 3,
                .state_node_count = 1,
                .store_ref_count = 0,
            }, .{
                .max_stores = 2,
            });
            try grt.std.testing.expectError(error.MaxStoresExceeded, store_limit);

            const node_limit = comptime validateBuilderCounts(.{
                .store_count = 1,
                .state_node_count = 5,
                .store_ref_count = 0,
            }, .{
                .max_state_nodes = 4,
            });
            try grt.std.testing.expectError(error.MaxStateNodesExceeded, node_limit);

            const ref_limit = comptime validateBuilderCounts(.{
                .store_count = 1,
                .state_node_count = 2,
                .store_ref_count = 6,
            }, .{
                .max_store_refs = 5,
            });
            try grt.std.testing.expectError(error.MaxStoreRefsExceeded, ref_limit);
        }
    };

    const Runner = struct {
        pub fn init(self: *@This(), allocator: glib.std.mem.Allocator) !void {
            _ = self;
            _ = allocator;
        }

        pub fn run(self: *@This(), t: *glib.testing.T, allocator: glib.std.mem.Allocator) bool {
            _ = self;

            TestCase.set_store_and_state_tracks_counts_and_overwrites(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.validate_state_path_reports_errors(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.collect_labels_accepts_singles_tuples_and_dedupes(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.make_builds_generated_store_type(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.make_allows_state_before_store_when_labels_resolve(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.validate_builder_reports_unknown_store_label(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            TestCase.validate_builder_counts_reports_capacity_errors(allocator) catch |err| {
                t.logFatal(@errorName(err));
                return false;
            };
            return true;
        }

        pub fn deinit(self: *@This(), allocator: glib.std.mem.Allocator) void {
            _ = self;
            _ = allocator;
        }
    };

    const Holder = struct {
        var runner: Runner = .{};
    };
    return glib.testing.TestRunner.make(Runner).new(&Holder.runner);
}
