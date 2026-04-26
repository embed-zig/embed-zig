const Dag = @This();

pub const Edge = struct {
    from_node_id: u32,
    edge_id: u32,
    to_node_id: u32,
};

initial_node_id: u32,
edges: []const Edge,

pub fn validate(comptime dag: Dag) void {
    const max_nodes = 1 + dag.edges.len * 2;
    var node_ids: [max_nodes]u32 = undefined;
    var node_count: usize = 0;

    appendUnique(&node_ids, &node_count, dag.initial_node_id);

    inline for (dag.edges, 0..) |edge, i| {
        if (edge.from_node_id == edge.to_node_id) {
            @compileError("zux.component.ui.flow.Dag self-edge is not allowed");
        }

        inline for (0..i) |j| {
            const prev = dag.edges[j];
            if (prev.from_node_id == edge.from_node_id and prev.edge_id == edge.edge_id) {
                @compileError("zux.component.ui.flow.Dag duplicate forward edge label from same node");
            }
            if (prev.to_node_id == edge.to_node_id and prev.edge_id == edge.edge_id) {
                @compileError("zux.component.ui.flow.Dag duplicate reverse edge label to same node");
            }
        }

        appendUnique(&node_ids, &node_count, edge.from_node_id);
        appendUnique(&node_ids, &node_count, edge.to_node_id);
    }

    var indegrees: [max_nodes]usize = [_]usize{0} ** max_nodes;
    inline for (dag.edges) |edge| {
        indegrees[indexOf(node_ids[0..node_count], edge.to_node_id)] += 1;
    }

    var processed: [max_nodes]bool = [_]bool{false} ** max_nodes;
    var processed_count: usize = 0;

    var pass: usize = 0;
    while (pass < node_count) : (pass += 1) {
        var progress = false;
        var node_index: usize = 0;
        while (node_index < node_count) : (node_index += 1) {
            if (processed[node_index] or indegrees[node_index] != 0) continue;

            processed[node_index] = true;
            processed_count += 1;
            progress = true;

            inline for (dag.edges) |edge| {
                if (edge.from_node_id != node_ids[node_index]) continue;
                indegrees[indexOf(node_ids[0..node_count], edge.to_node_id)] -= 1;
            }
        }

        if (!progress) break;
    }

    if (processed_count != node_count) {
        @compileError("zux.component.ui.flow.Dag must be acyclic");
    }
}

pub fn containsNode(comptime dag: Dag, node_id: u32) bool {
    if (dag.initial_node_id == node_id) return true;
    inline for (dag.edges) |edge| {
        if (edge.from_node_id == node_id or edge.to_node_id == node_id) return true;
    }
    return false;
}

pub fn forward(comptime dag: Dag, from_node_id: u32, edge_id: u32) ?u32 {
    inline for (dag.edges) |edge| {
        if (edge.from_node_id == from_node_id and edge.edge_id == edge_id) {
            return edge.to_node_id;
        }
    }
    return null;
}

pub fn reverse(comptime dag: Dag, to_node_id: u32, edge_id: u32) ?u32 {
    inline for (dag.edges) |edge| {
        if (edge.to_node_id == to_node_id and edge.edge_id == edge_id) {
            return edge.from_node_id;
        }
    }
    return null;
}

fn appendUnique(node_ids: anytype, node_count: *usize, node_id: u32) void {
    var i: usize = 0;
    while (i < node_count.*) : (i += 1) {
        if (node_ids[i] == node_id) return;
    }
    node_ids[node_count.*] = node_id;
    node_count.* += 1;
}

fn indexOf(node_ids: []const u32, node_id: u32) usize {
    for (node_ids, 0..) |existing, i| {
        if (existing == node_id) return i;
    }
    unreachable;
}
