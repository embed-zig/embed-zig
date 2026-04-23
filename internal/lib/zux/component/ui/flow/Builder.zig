const stdz = @import("stdz");
const builtin = stdz.builtin;
const Dag = @import("Dag.zig");
const ReducerTemplate = @import("Reducer.zig");
const StateTemplate = @import("State.zig");
const flow_event = @import("event.zig");

const Builder = @This();

pub const Edge = struct {
    from: []const u8,
    to: []const u8,
    label: []const u8,
};

nodes: []const []const u8 = &.{},
edge_labels: []const []const u8 = &.{},
edges: []const Edge = &.{},
initial_node: ?[]const u8 = null,

pub fn init() Builder {
    return .{};
}

pub fn addNode(self: *Builder, comptime node_name: []const u8) void {
    if (containsText(self.nodes, node_name)) {
        @compileError("zux.component.ui.flow.Builder duplicate node");
    }
    self.nodes = self.nodes ++ &[_][]const u8{node_name};
}

pub fn setInitial(self: *Builder, comptime node_name: []const u8) void {
    self.initial_node = node_name;
}

pub fn addEdge(
    self: *Builder,
    comptime from_name: []const u8,
    comptime to_name: []const u8,
    comptime edge_name: []const u8,
) void {
    self.edges = self.edges ++ &[_]Edge{.{
        .from = from_name,
        .to = to_name,
        .label = edge_name,
    }};

    appendUniqueLabel(&self.edge_labels, edge_name);
}

pub fn build(comptime self: Builder) type {
    comptime {
        if (self.initial_node == null) {
            @compileError("zux.component.ui.flow.Builder requires setInitial before build");
        }
        if (!containsText(self.nodes, self.initial_node.?)) {
            @compileError("zux.component.ui.flow.Builder initial node must be added with addNode");
        }
        for (self.edges) |edge| {
            if (!containsText(self.nodes, edge.from)) {
                @compileError("zux.component.ui.flow.Builder edge.from must be added with addNode");
            }
            if (!containsText(self.nodes, edge.to)) {
                @compileError("zux.component.ui.flow.Builder edge.to must be added with addNode");
            }
        }
    }

    const NodeLabelType = makeEnum(self.nodes, "zux.component.ui.flow.Builder duplicate node label");
    const EdgeLabelType = makeEnum(self.edge_labels, "zux.component.ui.flow.Builder duplicate edge label");
    const initial_node = @field(NodeLabelType, self.initial_node.?);
    return struct {
        pub const NodeLabel = NodeLabelType;
        pub const EdgeLabel = EdgeLabelType;
        pub const State = StateTemplate.make(NodeLabelType, EdgeLabelType, initial_node);

        const edges = makeEdges(self, NodeLabelType, EdgeLabelType);
        const dag: Dag = .{
            .initial_node_id = @intFromEnum(initial_node),
            .edges = &edges,
        };
        const forward_edge_counts = makeEdgeCounts(self, NodeLabelType, .forward);
        const reverse_edge_counts = makeEdgeCounts(self, NodeLabelType, .reverse);
        const forward_edge_lists = makeEdgeLists(self, NodeLabelType, EdgeLabelType, .forward);
        const reverse_edge_lists = makeEdgeLists(self, NodeLabelType, EdgeLabelType, .reverse);

        comptime {
            dag.validate();
        }

        pub fn Reducer(comptime lib: type) type {
            return ReducerTemplate.make(lib, State, dag, NodeLabelType);
        }

        pub fn initialState() State {
            return .{};
        }

        pub fn edgeId(edge: EdgeLabel) u32 {
            return @intFromEnum(edge);
        }

        pub fn forwardEdges(node: NodeLabel) []const EdgeLabel {
            const index = @intFromEnum(node);
            return forward_edge_lists[index][0..forward_edge_counts[index]];
        }

        pub fn reverseEdges(node: NodeLabel) []const EdgeLabel {
            const index = @intFromEnum(node);
            return reverse_edge_lists[index][0..reverse_edge_counts[index]];
        }
    };
}

fn makeEdges(comptime self: Builder, comptime Node: type, comptime EdgeLabel: type) [self.edges.len]Dag.Edge {
    var edges: [self.edges.len]Dag.Edge = undefined;

    inline for (self.edges, 0..) |edge, i| {
        edges[i] = .{
            .from_node_id = @intFromEnum(@field(Node, edge.from)),
            .edge_id = @intFromEnum(@field(EdgeLabel, edge.label)),
            .to_node_id = @intFromEnum(@field(Node, edge.to)),
        };
    }
    return edges;
}

fn makeEdgeCounts(comptime self: Builder, comptime NodeLabel: type, comptime direction: flow_event.Direction) [self.nodes.len]usize {
    var counts: [self.nodes.len]usize = [_]usize{0} ** self.nodes.len;

    inline for (self.edges) |edge| {
        const node = switch (direction) {
            .forward => @field(NodeLabel, edge.from),
            .reverse => @field(NodeLabel, edge.to),
        };
        counts[@intFromEnum(node)] += 1;
    }

    return counts;
}

fn makeEdgeLists(
    comptime self: Builder,
    comptime NodeLabel: type,
    comptime EdgeLabel: type,
    comptime direction: flow_event.Direction,
) [self.nodes.len][self.edges.len]EdgeLabel {
    var lists: [self.nodes.len][self.edges.len]EdgeLabel = undefined;
    var counts: [self.nodes.len]usize = [_]usize{0} ** self.nodes.len;

    inline for (self.edges) |edge| {
        const node = switch (direction) {
            .forward => @field(NodeLabel, edge.from),
            .reverse => @field(NodeLabel, edge.to),
        };
        const edge_label = @field(EdgeLabel, edge.label);
        const node_index = @intFromEnum(node);
        lists[node_index][counts[node_index]] = edge_label;
        counts[node_index] += 1;
    }

    return lists;
}

fn containsText(comptime labels: []const []const u8, comptime label: []const u8) bool {
    inline for (labels) |existing| {
        if (comptimeEql(existing, label)) return true;
    }
    return false;
}

fn appendUniqueLabel(labels: *[]const []const u8, comptime label: []const u8) void {
    if (containsText(labels.*, label)) return;
    labels.* = labels.* ++ &[_][]const u8{label};
}

fn makeEnum(comptime labels: []const []const u8, comptime duplicate_message: []const u8) type {
    const count = labels.len;
    var fields: [count]builtin.Type.EnumField = undefined;

    inline for (labels, 0..) |label, i| {
        const name = label;
        inline for (0..i) |j| {
            if (comptimeEql(fields[j].name, name)) {
                @compileError(duplicate_message);
            }
        }
        fields[i] = .{
            .name = sentinelName(name),
            .value = i,
        };
    }

    return @Type(.{
        .@"enum" = .{
            .tag_type = if (count == 0) u0 else stdz.math.IntFittingRange(0, count - 1),
            .fields = &fields,
            .decls = &.{},
            .is_exhaustive = true,
        },
    });
}

fn comptimeEql(comptime a: []const u8, comptime b: []const u8) bool {
    if (a.len != b.len) return false;
    inline for (a, 0..) |byte, i| {
        if (b[i] != byte) return false;
    }
    return true;
}

fn sentinelName(comptime text: []const u8) [:0]const u8 {
    const terminated = text ++ "\x00";
    return terminated[0..text.len :0];
}
