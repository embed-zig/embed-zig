const std = @import("std");

pub const StepKind = enum {
    send,
    wait,
    expect,
    match_until,
};

pub const Step = struct {
    kind: StepKind,
    payload: []const u8,
    count: ?usize = null,
    line_no: usize,
};

pub const Track = struct {
    dev: []const u8,
    steps: []const Step,
};

pub const TestCase = struct {
    name: []const u8,
    tracks: []const Track,
    source: []const u8,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *TestCase) void {
        self.arena.deinit();
    }
};

pub const ParseError = error{
    InvalidStep,
    MissingTracks,
    OutOfMemory,
};

pub fn loadFromFile(allocator: std.mem.Allocator, path: []const u8) !TestCase {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    const source = try std.fs.cwd().readFileAlloc(a, path, 1024 * 1024);
    return parseFromBytes(arena, path, source);
}

pub fn parseFromBytes(arena: std.heap.ArenaAllocator, source_path: []const u8, source: []const u8) ParseError!TestCase {
    var case_arena = arena;
    const a = case_arena.allocator();

    var maybe_name: ?[]const u8 = null;

    const TrackBuilder = struct {
        dev: []const u8,
        steps: std.ArrayList(Step),
    };

    var track_builders = std.ArrayList(TrackBuilder).empty;
    var current_track: ?*TrackBuilder = null;

    var in_match_until = false;
    var match_target: ?[]const u8 = null;
    var match_count: ?usize = null;
    var match_line: usize = 0;

    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| {
        line_no += 1;
        const no_cr = std.mem.trimRight(u8, raw_line, "\r");
        const line = std.mem.trim(u8, no_cr, " \t");
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "#")) continue;
        if (std.mem.eql(u8, line, "tracks:")) continue;

        if (in_match_until) {
            if (std.mem.startsWith(u8, line, "target:")) {
                match_target = std.mem.trim(u8, line["target:".len..], " \t");
                continue;
            }
            if (std.mem.startsWith(u8, line, "count:")) {
                const val = std.mem.trim(u8, line["count:".len..], " \t");
                match_count = std.fmt.parseInt(usize, val, 10) catch return error.InvalidStep;
                continue;
            }
            if (current_track) |t| {
                const target = match_target orelse return error.InvalidStep;
                t.steps.append(a, .{
                    .kind = .match_until,
                    .payload = target,
                    .count = match_count,
                    .line_no = match_line,
                }) catch return error.OutOfMemory;
            }
            in_match_until = false;
            match_target = null;
            match_count = null;
        }

        if (std.mem.startsWith(u8, line, "name:")) {
            maybe_name = std.mem.trim(u8, line["name:".len..], " \t");
            continue;
        }

        if (!std.mem.startsWith(u8, line, "-") and std.mem.endsWith(u8, line, ":")) {
            const dev = line[0 .. line.len - 1];
            if (!std.mem.eql(u8, dev, "name") and !std.mem.eql(u8, dev, "tracks")) {
                track_builders.append(a, .{
                    .dev = dev,
                    .steps = .empty,
                }) catch return error.OutOfMemory;
                current_track = &track_builders.items[track_builders.items.len - 1];
                continue;
            }
        }

        const t = current_track orelse continue;

        if (std.mem.startsWith(u8, line, "- send:")) {
            const val = std.mem.trim(u8, line["- send:".len..], " \t");
            if (val.len == 0) return error.InvalidStep;
            t.steps.append(a, .{ .kind = .send, .payload = val, .line_no = line_no }) catch return error.OutOfMemory;
            continue;
        }

        if (std.mem.startsWith(u8, line, "- wait:")) {
            const val = std.mem.trim(u8, line["- wait:".len..], " \t");
            if (val.len == 0) return error.InvalidStep;
            t.steps.append(a, .{ .kind = .wait, .payload = val, .line_no = line_no }) catch return error.OutOfMemory;
            continue;
        }

        if (std.mem.startsWith(u8, line, "- expect:")) {
            const val = std.mem.trim(u8, line["- expect:".len..], " \t");
            if (val.len == 0) return error.InvalidStep;
            t.steps.append(a, .{ .kind = .expect, .payload = val, .line_no = line_no }) catch return error.OutOfMemory;
            continue;
        }

        if (std.mem.startsWith(u8, line, "- match_until:")) {
            in_match_until = true;
            match_line = line_no;
            match_target = null;
            match_count = null;
            continue;
        }
    }

    if (in_match_until) {
        if (current_track) |t| {
            const target = match_target orelse return error.InvalidStep;
            t.steps.append(a, .{
                .kind = .match_until,
                .payload = target,
                .count = match_count,
                .line_no = match_line,
            }) catch return error.OutOfMemory;
        }
    }

    if (track_builders.items.len == 0) return error.MissingTracks;

    var tracks = std.ArrayList(Track).empty;
    for (track_builders.items) |*tb| {
        tracks.append(a, .{
            .dev = tb.dev,
            .steps = tb.steps.toOwnedSlice(a) catch return error.OutOfMemory,
        }) catch return error.OutOfMemory;
    }

    return .{
        .name = maybe_name orelse std.fs.path.basename(source_path),
        .tracks = tracks.toOwnedSlice(a) catch return error.OutOfMemory,
        .source = source_path,
        .arena = case_arena,
    };
}
