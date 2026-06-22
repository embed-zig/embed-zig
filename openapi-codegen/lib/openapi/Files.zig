const glib = @import("glib");
const std = glib.std;
const Spec = @import("Spec.zig");

const Self = @This();

items: []const Entry = &.{},

pub const Entry = struct {
    name: []const u8 = "",
    spec: Spec = .{},
};

pub const SchemaRef = struct {
    file_name: []const u8,
    schema_name: []const u8,
};

pub const PathRef = struct {
    file_name: []const u8,
    path_name: []const u8,
};

pub const ParameterRef = struct {
    file_name: []const u8,
    parameter_name: []const u8,
};

pub const ResponseRef = struct {
    file_name: []const u8,
    response_name: []const u8,
};

pub const RequestBodyRef = struct {
    file_name: []const u8,
    request_body_name: []const u8,
};

pub const ResolvedSchema = struct {
    file_name: []const u8,
    schema_name: []const u8,
    schema: Spec.SchemaOrRef,
};

pub const ResolvedPathItem = struct {
    file_name: []const u8,
    path_name: []const u8,
    path_item: Spec.PathItemOrRef,
};

pub const ResolvedParameter = struct {
    file_name: []const u8,
    parameter_name: []const u8,
    parameter: Spec.ParameterOrRef,
};

pub const ResolvedResponse = struct {
    file_name: []const u8,
    response_name: []const u8,
    response: Spec.ResponseOrRef,
};

pub const ResolvedRequestBody = struct {
    file_name: []const u8,
    request_body_name: []const u8,
    request_body: Spec.RequestBodyOrRef,
};

const JsonReference = struct {
    file_name: []const u8,
    pointer: []const u8,
};

pub fn findFile(self: Self, name: []const u8) ?Spec {
    for (self.items) |item| {
        if (std.mem.eql(u8, item.name, name)) return item.spec;
    }
    return null;
}

pub fn findSchema(self: Self, file_name: []const u8, schema_name: []const u8) ?Spec.SchemaOrRef {
    const spec = self.findFile(file_name) orelse return null;
    return spec.findSchema(schema_name);
}

pub fn findPath(self: Self, file_name: []const u8, path_name: []const u8) ?Spec.PathItemOrRef {
    const spec = self.findFile(file_name) orelse return null;
    return spec.findPath(path_name);
}

pub fn findParameter(self: Self, file_name: []const u8, parameter_name: []const u8) ?Spec.ParameterOrRef {
    const spec = self.findFile(file_name) orelse return null;
    const components = spec.components orelse return null;
    return Spec.findNamed(Spec.ParameterOrRef, components.parameters, parameter_name);
}

pub fn findResponse(self: Self, file_name: []const u8, response_name: []const u8) ?Spec.ResponseOrRef {
    const spec = self.findFile(file_name) orelse return null;
    const components = spec.components orelse return null;
    return Spec.findNamed(Spec.ResponseOrRef, components.responses, response_name);
}

pub fn findRequestBody(self: Self, file_name: []const u8, request_body_name: []const u8) ?Spec.RequestBodyOrRef {
    const spec = self.findFile(file_name) orelse return null;
    const components = spec.components orelse return null;
    return Spec.findNamed(Spec.RequestBodyOrRef, components.request_bodies, request_body_name);
}

pub fn parseSchemaRef(comptime current_file_name: []const u8, comptime ref_path: []const u8) ?SchemaRef {
    const parsed = parseNamedRef(current_file_name, ref_path, "#/components/schemas/") orelse return null;

    return .{
        .file_name = parsed.file_name,
        .schema_name = parsed.name,
    };
}

pub fn resolveSchemaRef(self: Self, comptime current_file_name: []const u8, comptime ref_path: []const u8) ?ResolvedSchema {
    const parsed = parseSchemaRef(current_file_name, ref_path) orelse return null;
    const schema = self.findSchema(parsed.file_name, parsed.schema_name) orelse return null;

    return .{
        .file_name = parsed.file_name,
        .schema_name = parsed.schema_name,
        .schema = schema,
    };
}

pub fn parsePathRef(comptime current_file_name: []const u8, comptime ref_path: []const u8) ?PathRef {
    const parsed = parseNamedRef(current_file_name, ref_path, "#/paths/") orelse return null;

    return .{
        .file_name = parsed.file_name,
        .path_name = parsed.name,
    };
}

pub fn resolvePathRef(self: Self, comptime current_file_name: []const u8, comptime ref_path: []const u8) ?ResolvedPathItem {
    const parsed = parsePathRef(current_file_name, ref_path) orelse return null;
    const path_item = self.findPath(parsed.file_name, parsed.path_name) orelse return null;

    return .{
        .file_name = parsed.file_name,
        .path_name = parsed.path_name,
        .path_item = path_item,
    };
}

pub fn parseParameterRef(comptime current_file_name: []const u8, comptime ref_path: []const u8) ?ParameterRef {
    const parsed = parseNamedRef(current_file_name, ref_path, "#/components/parameters/") orelse return null;

    return .{
        .file_name = parsed.file_name,
        .parameter_name = parsed.name,
    };
}

pub fn resolveParameterRef(self: Self, comptime current_file_name: []const u8, comptime ref_path: []const u8) ?ResolvedParameter {
    const parsed = parseParameterRef(current_file_name, ref_path) orelse return null;
    const parameter = self.findParameter(parsed.file_name, parsed.parameter_name) orelse return null;

    return .{
        .file_name = parsed.file_name,
        .parameter_name = parsed.parameter_name,
        .parameter = parameter,
    };
}

pub fn parseResponseRef(comptime current_file_name: []const u8, comptime ref_path: []const u8) ?ResponseRef {
    const parsed = parseNamedRef(current_file_name, ref_path, "#/components/responses/") orelse return null;

    return .{
        .file_name = parsed.file_name,
        .response_name = parsed.name,
    };
}

pub fn resolveResponseRef(self: Self, comptime current_file_name: []const u8, comptime ref_path: []const u8) ?ResolvedResponse {
    const parsed = parseResponseRef(current_file_name, ref_path) orelse return null;
    const response = self.findResponse(parsed.file_name, parsed.response_name) orelse return null;

    return .{
        .file_name = parsed.file_name,
        .response_name = parsed.response_name,
        .response = response,
    };
}

pub fn parseRequestBodyRef(comptime current_file_name: []const u8, comptime ref_path: []const u8) ?RequestBodyRef {
    const parsed = parseNamedRef(current_file_name, ref_path, "#/components/requestBodies/") orelse return null;

    return .{
        .file_name = parsed.file_name,
        .request_body_name = parsed.name,
    };
}

pub fn resolveRequestBodyRef(self: Self, comptime current_file_name: []const u8, comptime ref_path: []const u8) ?ResolvedRequestBody {
    const parsed = parseRequestBodyRef(current_file_name, ref_path) orelse return null;
    const request_body = self.findRequestBody(parsed.file_name, parsed.request_body_name) orelse return null;

    return .{
        .file_name = parsed.file_name,
        .request_body_name = parsed.request_body_name,
        .request_body = request_body,
    };
}

fn parseNamedRef(comptime current_file_name: []const u8, comptime ref_path: []const u8, comptime prefix: []const u8) ?struct {
    file_name: []const u8,
    name: []const u8,
} {
    const reference = comptime parseJsonReference(current_file_name, ref_path) orelse return null;
    if (!std.mem.startsWith(u8, reference.pointer, prefix)) return null;

    return .{
        .file_name = reference.file_name,
        .name = decodeJsonPointerSegment(reference.pointer[prefix.len..]),
    };
}

fn parseJsonReference(comptime current_file_name: []const u8, comptime ref_path: []const u8) ?JsonReference {
    const anchor_index = comptime std.mem.indexOfScalar(u8, ref_path, '#') orelse return null;
    const file_name = if (anchor_index == 0)
        current_file_name
    else
        normalizeRefFileName(current_file_name, ref_path[0..anchor_index]);

    return .{
        .file_name = file_name,
        .pointer = ref_path[anchor_index..],
    };
}

fn normalizeRefFileName(comptime current_file_name: []const u8, comptime ref_file_name: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, ref_file_name, "./") and !std.mem.startsWith(u8, ref_file_name, "../")) {
        return ref_file_name;
    }

    const current_dir = dirname(current_file_name);
    const joined = if (current_dir.len == 0)
        ref_file_name
    else
        glib.std.fmt.comptimePrint("{s}/{s}", .{ current_dir, ref_file_name });

    return normalizeRelativePath(joined);
}

fn dirname(comptime file_name: []const u8) []const u8 {
    const index = std.mem.lastIndexOfScalar(u8, file_name, '/') orelse return "";
    return file_name[0..index];
}

fn normalizeRelativePath(comptime path: []const u8) []const u8 {
    comptime var segments: [maxSegments(path)][]const u8 = undefined;
    comptime var segment_count: usize = 0;
    comptime var index: usize = 0;

    inline while (index <= path.len) {
        const start = index;
        while (index < path.len and path[index] != '/') : (index += 1) {}
        const segment = path[start..index];

        if (segment.len == 0 or std.mem.eql(u8, segment, ".")) {
            // Skip empty and current-dir segments.
        } else if (std.mem.eql(u8, segment, "..")) {
            if (segment_count != 0 and !std.mem.eql(u8, segments[segment_count - 1], "..")) {
                segment_count -= 1;
            } else {
                segments[segment_count] = segment;
                segment_count += 1;
            }
        } else {
            segments[segment_count] = segment;
            segment_count += 1;
        }

        index += 1;
    }

    comptime var output_len: usize = 2;
    inline for (segments[0..segment_count], 0..) |segment, i| {
        if (i != 0) output_len += 1;
        output_len += segment.len;
    }

    comptime var out: [output_len]u8 = undefined;
    out[0] = '.';
    out[1] = '/';
    comptime var out_index: usize = 2;
    inline for (segments[0..segment_count], 0..) |segment, i| {
        if (i != 0) {
            out[out_index] = '/';
            out_index += 1;
        }
        inline for (segment) |c| {
            out[out_index] = c;
            out_index += 1;
        }
    }
    return glib.std.fmt.comptimePrint("{s}", .{out});
}

fn maxSegments(comptime path: []const u8) usize {
    comptime var count: usize = 1;
    inline for (path) |c| {
        if (c == '/') count += 1;
    }
    return count;
}

fn decodeJsonPointerSegment(comptime encoded: []const u8) []const u8 {
    comptime var extra: usize = 0;
    comptime var index: usize = 0;
    inline while (index < encoded.len) : (index += 1) {
        if (encoded[index] == '~' and index + 1 < encoded.len) {
            extra += 1;
            index += 1;
        }
    }

    comptime var buffer: [encoded.len - extra]u8 = undefined;
    comptime var out_index: usize = 0;
    index = 0;
    inline while (index < encoded.len) : (index += 1) {
        if (encoded[index] == '~' and index + 1 < encoded.len) {
            const next = encoded[index + 1];
            buffer[out_index] = switch (next) {
                '0' => '~',
                '1' => '/',
                else => next,
            };
            out_index += 1;
            index += 1;
            continue;
        }

        buffer[out_index] = encoded[index];
        out_index += 1;
    }

    return std.fmt.comptimePrint("{s}", .{buffer[0..out_index]});
}
