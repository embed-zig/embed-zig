const std = @import("std");
const embed = @import("embed");
const openapi = @import("openapi");
const models_mod = @import("models.zig");

const Files = openapi.Files;
const Spec = openapi.Spec;
const Type = std.builtin.Type;

const RootFile = struct {
    name: []const u8,
    spec: Spec,
};

const OperationRef = struct {
    file_name: []const u8,
    field_name: [:0]const u8,
    method: []const u8,
    path: []const u8,
    path_item: Spec.PathItem,
    operation: Spec.Operation,
};

const ResolvedParameter = struct {
    field_name: [:0]const u8,
    original_name: []const u8,
    location: Spec.ParameterLocation,
    required: bool,
    field_type: type,
    encoding: ParameterEncoding,
};

const RuntimeParameter = struct {
    field_name: [:0]const u8,
    original_name: []const u8,
    location: Spec.ParameterLocation,
    encoding: ParameterEncoding,
};

const ResolvedParameterOrigin = struct {
    file_name: []const u8,
    parameter: Spec.Parameter,
};

const ResolvedResponseOrigin = struct {
    file_name: []const u8,
    response: Spec.Response,
};

const ResolvedRequestBodyOrigin = struct {
    file_name: []const u8,
    request_body: Spec.RequestBody,
};

const ParameterEncoding = enum {
    scalar,
    json,
};

const RequestPayloadKind = enum {
    json,
    raw,
};

const SelectedRequestBody = struct {
    required: bool,
    body_type: type,
    payload_kind: RequestPayloadKind,
    content_type: []const u8,
};

const ResponsePayloadKind = enum {
    none,
    json,
    raw,
    sse,
};

const ResponseVariant = struct {
    field_name: [:0]const u8,
    status_name: []const u8,
    status_code: ?u16,
    payload_kind: ResponsePayloadKind,
    payload_type: type,
};

pub fn make(comptime lib: type, comptime files: Files) type {
    @setEvalBranchQuota(300_000);

    const root = rootFile(files);
    const net = embed.net.make(lib);
    const Http = net.http;
    const Models = models_mod.make(files);
    const default_base_url = copyString(defaultBaseUrl(root.spec));
    const spec_title = copyString(root.spec.info.title);
    const spec_version = copyString(root.spec.info.version);

    const State = struct {
        allocator: lib.mem.Allocator,
        http_client: *Http.Client,
        base_url: []const u8,
    };

    const Operations = makeOperations(lib, files, root, State);

    return struct {
        state: *State,
        operations: Operations,

        const Self = @This();

        pub const models = Models;
        pub const OperationSet = Operations;
        pub const HttpClient = Http.Client;
        pub const Context = embed.context.Context;
        pub const Options = struct {
            allocator: lib.mem.Allocator,
            http_client: *Http.Client,
            base_url: []const u8 = default_base_url,
        };

        pub fn init(options: Options) anyerror!Self {
            const state = try options.allocator.create(State);
            errdefer options.allocator.destroy(state);

            state.* = .{
                .allocator = options.allocator,
                .http_client = options.http_client,
                .base_url = options.base_url,
            };

            return .{
                .state = state,
                .operations = initOperations(Operations, state),
            };
        }

        pub fn deinit(self: *Self) void {
            const allocator = self.state.allocator;
            allocator.destroy(self.state);
            self.* = undefined;
        }

        pub fn specTitle(self: Self) []const u8 {
            _ = self;
            return spec_title;
        }

        pub fn specVersion(self: Self) []const u8 {
            _ = self;
            return spec_version;
        }
    };
}

fn makeOperations(
    comptime lib: type,
    comptime files: Files,
    comptime root: RootFile,
    comptime State: type,
) type {
    const operations = collectOperations(files, root);
    var fields: [operations.len]Type.StructField = undefined;

    for (operations, 0..) |operation_ref, i| {
        const Operation = OperationHandle(lib, files, operation_ref, State);
        ensureUniqueFieldName(fields[0..i], operation_ref.field_name, "operation");
        fields[i] = .{
            .name = operation_ref.field_name,
            .type = Operation,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(Operation),
        };
    }

    return @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = &fields,
        .decls = &.{},
        .is_tuple = false,
    } });
}

fn OperationHandle(
    comptime lib: type,
    comptime files: Files,
    comptime operation_ref: OperationRef,
    comptime State: type,
) type {
    const net = embed.net.make(lib);
    const Http = net.http;
    const parameters_slice = collectEffectiveParameters(files, operation_ref.file_name, operation_ref.path_item, operation_ref.operation, operation_ref.field_name);
    const parameters = blk: {
        var items: [parameters_slice.len]ResolvedParameter = undefined;
        for (parameters_slice, 0..) |parameter, i| items[i] = parameter;
        break :blk items;
    };
    const runtime_parameters = blk: {
        var items: [parameters.len]RuntimeParameter = undefined;
        for (parameters, 0..) |parameter, i| {
            items[i] = .{
                .field_name = parameter.field_name,
                .original_name = parameter.original_name,
                .location = parameter.location,
                .encoding = parameter.encoding,
            };
        }
        break :blk items;
    };
    const request_body = selectRequestBody(lib, files, operation_ref.file_name, operation_ref.operation.request_body, operation_ref.field_name);
    const ArgsType = makeArgsType(parameters, request_body);
    const response_variants_slice = collectResponseVariants(files, operation_ref.file_name, operation_ref.operation.responses, operation_ref.field_name);
    const response_variants = blk: {
        var items: [response_variants_slice.len]ResponseVariant = undefined;
        for (response_variants_slice, 0..) |variant, i| items[i] = variant;
        break :blk items;
    };
    const ResponsePayload = makeResponseType(lib, response_variants);
    const ResponseType = makeOwnedResponseType(lib, ResponsePayload, response_variants);
    const method = copyString(operation_ref.method);
    const path = copyString(operation_ref.path);

    return struct {
        state: *State,

        const Self = @This();

        pub const Args = ArgsType;
        pub const Response = ResponseType;

        pub fn init(state: *State) Self {
            return .{ .state = state };
        }

        const SendResult = if (ResponseType == void) void else *ResponseType;

        pub fn send(self: Self, ctx: embed.context.Context, allocator: lib.mem.Allocator, args: ArgsType) anyerror!SendResult {
            var url_builder = try lib.ArrayList(u8).initCapacity(allocator, 0);
            defer url_builder.deinit(allocator);

            try appendBaseUrl(lib, allocator, &url_builder, self.state.base_url, path);
            try appendResolvedPath(lib, allocator, &url_builder, path, runtime_parameters, args);
            try appendQueryString(lib, allocator, &url_builder, runtime_parameters, args);

            const raw_url = try url_builder.toOwnedSlice(allocator);
            defer allocator.free(raw_url);

            var request = try Http.Request.init(allocator, method, raw_url);
            defer request.deinit();
            request = request.withContext(ctx);

            var owned_header_values = try lib.ArrayList([]const u8).initCapacity(allocator, 0);
            defer {
                for (owned_header_values.items) |owned| allocator.free(owned);
                owned_header_values.deinit(allocator);
            }

            try appendHeaderParameters(
                lib,
                allocator,
                &request,
                runtime_parameters,
                args,
                &owned_header_values,
            );

            try appendCookieParameters(
                lib,
                allocator,
                &request,
                runtime_parameters,
                args,
                &owned_header_values,
            );

            var body_bytes: ?[]u8 = null;
            defer if (body_bytes) |owned| allocator.free(owned);
            var force_connection_close = false;

            if (request_body) |selected_body| {
                if (@hasField(ArgsType, "body")) {
                    const body_value = @field(args, "body");
                    switch (selected_body.payload_kind) {
                        .json => {
                            switch (@typeInfo(@TypeOf(body_value))) {
                                .optional => {
                                    if (body_value) |payload| {
                                        body_bytes = try encodeJsonBody(lib, allocator, payload);
                                    }
                                },
                                else => {
                                    body_bytes = try encodeJsonBody(lib, allocator, body_value);
                                },
                            }
                        },
                        .raw => {
                            force_connection_close = true;
                            switch (@typeInfo(@TypeOf(body_value))) {
                                .optional => {
                                    if (body_value) |rc| {
                                        body_bytes = try readReadCloser(lib, allocator, rc);
                                    }
                                },
                                else => {
                                    body_bytes = try readReadCloser(lib, allocator, body_value);
                                },
                            }
                        },
                    }
                }
            }

            if (body_bytes) |payload| {
                var body = FixedBufferBody{ .bytes = payload };
                request = request.withBody(Http.ReadCloser.init(&body));
                request.content_length = @intCast(payload.len);
                try request.addHeader(Http.Header.content_type, request_body.?.content_type);
            }

            if (force_connection_close) {
                try request.addHeader(Http.Header.connection, "close");
            }

            if (responseWantsJson(response_variants)) {
                try request.addHeader(Http.Header.accept, "application/json");
            }

            const response_ptr = try self.state.allocator.create(Http.Response);
            errdefer self.state.allocator.destroy(response_ptr);
            response_ptr.* = try self.state.http_client.do(&request);
            var dispose_http_response: bool = true;
            errdefer if (dispose_http_response) response_ptr.deinit();

            inline for (response_variants) |variant| {
                if (variant.status_code) |status_code| {
                    if (response_ptr.status_code == status_code) {
                        const out = try decodeResponseVariant(lib, ResponseType, allocator, response_ptr, variant);
                        dispose_http_response = false;
                        return out;
                    }
                }
            }

            inline for (response_variants) |variant| {
                if (variant.status_code == null) {
                    const out = try decodeResponseVariant(lib, ResponseType, allocator, response_ptr, variant);
                    dispose_http_response = false;
                    return out;
                }
            }

            return error.UnexpectedStatusCode;
        }

        /// Releases only the outer response handle. For streaming payloads, callers
        /// must close the inner `ReadCloser` / `sse.Reader` first.
        pub fn deinitResponse(self: Self, response_value: if (ResponseType == void) void else *ResponseType) void {
            if (ResponseType == void) return;
            _ = self;
            response_value.deinit();
        }
    };
}

fn makeOwnedResponseType(comptime lib: type, comptime ResponsePayload: type, comptime variants: anytype) type {
    if (ResponsePayload == void) return void;

    return struct {
        allocator: lib.mem.Allocator,
        /// Heap `Response` from `Client.do`; kept alive until caller-owned stream teardown finishes.
        http_response: *embed.net.make(lib).http.Response,
        value: ResponsePayload,
        /// If a raw or SSE response has no body reader, the caller-owned stream points here.
        raw_empty_body: FixedBufferBody = .{ .bytes = "" },

        const Self = @This();

        /// Releases the outer HTTP response and wrapper allocation. `.raw` and `.sse`
        /// payload cleanup is caller-owned and must happen before this method.
        pub fn deinit(self: *Self) void {
            const allocator = self.allocator;
            const resp_ptr = self.http_response;

            switch (self.value) {
                inline else => |*payload, tag| {
                    inline for (variants) |variant| {
                        if (tag != @field(std.meta.FieldEnum(ResponsePayload), variant.field_name)) continue;
                        switch (variant.payload_kind) {
                            .none => {},
                            .json => payload.deinit(),
                            .raw, .sse => {},
                        }
                    }
                },
            }

            resp_ptr.deinit();
            allocator.destroy(resp_ptr);
            self.* = undefined;
            allocator.destroy(self);
        }
    };
}

const FixedBufferBody = struct {
    bytes: []const u8,
    offset: usize = 0,

    pub fn read(self: *@This(), buffer: []u8) anyerror!usize {
        const remaining = self.bytes[self.offset..];
        const amount = @min(buffer.len, remaining.len);
        @memcpy(buffer[0..amount], remaining[0..amount]);
        self.offset += amount;
        return amount;
    }

    pub fn close(_: *@This()) void {}
};

fn initOperations(comptime Operations: type, state: anytype) Operations {
    var operations: Operations = undefined;
    inline for (@typeInfo(Operations).@"struct".fields) |field| {
        @field(operations, field.name) = field.type.init(state);
    }
    return operations;
}

fn rootFile(comptime files: Files) RootFile {
    if (files.items.len == 0) {
        @compileError("client.make requires at least one OpenAPI file.");
    }

    return .{
        .name = files.items[0].name,
        .spec = files.items[0].spec,
    };
}

fn collectOperations(comptime files: Files, comptime root: RootFile) []const OperationRef {
    const total = operationCount(files, root.name, root.spec);
    comptime var operations: [total]OperationRef = undefined;
    comptime var index: usize = 0;

    inline for (root.spec.paths) |named_path| {
        appendPathItemOperations(&operations, &index, files, root.name, named_path.name, named_path.value);
    }

    return operations[0..];
}

fn appendPathItemOperations(
    comptime operations: []OperationRef,
    comptime index: *usize,
    comptime files: Files,
    comptime current_file_name: []const u8,
    comptime path: []const u8,
    comptime path_item_or_ref: Spec.PathItemOrRef,
) void {
    switch (path_item_or_ref) {
        .path_item => |path_item| {
            appendOperation(operations, index, current_file_name, path, path_item, path_item.get, "GET");
            appendOperation(operations, index, current_file_name, path, path_item, path_item.put, "PUT");
            appendOperation(operations, index, current_file_name, path, path_item, path_item.post, "POST");
            appendOperation(operations, index, current_file_name, path, path_item, path_item.delete, "DELETE");
            appendOperation(operations, index, current_file_name, path, path_item, path_item.options, "OPTIONS");
            appendOperation(operations, index, current_file_name, path, path_item, path_item.head, "HEAD");
            appendOperation(operations, index, current_file_name, path, path_item, path_item.patch, "PATCH");
            appendOperation(operations, index, current_file_name, path, path_item, path_item.trace, "TRACE");
        },
        .reference => |reference| {
            const resolved = files.resolvePathRef(current_file_name, reference.ref_path) orelse @compileError(std.fmt.comptimePrint(
                "Unsupported path reference '{s}'.",
                .{reference.ref_path},
            ));
            appendPathItemOperations(operations, index, files, resolved.file_name, path, resolved.path_item);
        },
    }
}

fn appendOperation(
    comptime operations: []OperationRef,
    comptime index: *usize,
    comptime current_file_name: []const u8,
    comptime path: []const u8,
    comptime path_item: Spec.PathItem,
    comptime operation: ?Spec.Operation,
    comptime method: []const u8,
) void {
    const op = operation orelse return;
    const operation_id = op.operation_id orelse deriveOperationName(method, path);
    const field_name = zigIdentifier(operation_id);
    ensureUniqueOperationName(operations[0..index.*], field_name, operation_id);

    operations[index.*] = .{
        .file_name = copyString(current_file_name),
        .field_name = field_name,
        .method = method,
        .path = copyString(path),
        .path_item = path_item,
        .operation = op,
    };
    index.* += 1;
}

fn operationCount(comptime files: Files, comptime current_file_name: []const u8, comptime spec: Spec) usize {
    comptime var total: usize = 0;

    inline for (spec.paths) |named_path| {
        total += pathItemOperationCount(files, current_file_name, named_path.value);
    }

    return total;
}

fn pathItemOperationCount(
    comptime files: Files,
    comptime current_file_name: []const u8,
    comptime path_item_or_ref: Spec.PathItemOrRef,
) usize {
    return switch (path_item_or_ref) {
        .reference => |reference| blk: {
            const resolved = files.resolvePathRef(current_file_name, reference.ref_path) orelse @compileError(std.fmt.comptimePrint(
                "Unsupported path reference '{s}'.",
                .{reference.ref_path},
            ));
            break :blk pathItemOperationCount(files, resolved.file_name, resolved.path_item);
        },
        .path_item => |path_item| @as(usize, @intFromBool(path_item.get != null)) +
            @as(usize, @intFromBool(path_item.put != null)) +
            @as(usize, @intFromBool(path_item.post != null)) +
            @as(usize, @intFromBool(path_item.delete != null)) +
            @as(usize, @intFromBool(path_item.options != null)) +
            @as(usize, @intFromBool(path_item.head != null)) +
            @as(usize, @intFromBool(path_item.patch != null)) +
            @as(usize, @intFromBool(path_item.trace != null)),
    };
}

fn makeArgsType(
    comptime parameters: anytype,
    comptime request_body: ?SelectedRequestBody,
) type {
    const path_count = countParameters(parameters, .path);
    const query_count = countParameters(parameters, .query);
    const header_count = countParameters(parameters, .header);
    const cookie_count = countParameters(parameters, .cookie);
    const body_count: usize = if (request_body != null) 1 else 0;
    const total = @as(usize, @intFromBool(path_count != 0)) +
        @as(usize, @intFromBool(query_count != 0)) +
        @as(usize, @intFromBool(header_count != 0)) +
        @as(usize, @intFromBool(cookie_count != 0)) +
        body_count;

    var fields: [total]Type.StructField = undefined;
    var index: usize = 0;

    if (path_count != 0) {
        const PathArgs = makeParameterGroupType(parameters, .path);
        fields[index] = .{
            .name = "path",
            .type = PathArgs,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(PathArgs),
        };
        index += 1;
    }

    if (query_count != 0) {
        const QueryArgs = makeParameterGroupType(parameters, .query);
        fields[index] = .{
            .name = "query",
            .type = QueryArgs,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(QueryArgs),
        };
        index += 1;
    }

    if (header_count != 0) {
        const HeaderArgs = makeParameterGroupType(parameters, .header);
        fields[index] = .{
            .name = "header",
            .type = HeaderArgs,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(HeaderArgs),
        };
        index += 1;
    }

    if (cookie_count != 0) {
        const CookieArgs = makeParameterGroupType(parameters, .cookie);
        fields[index] = .{
            .name = "cookie",
            .type = CookieArgs,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(CookieArgs),
        };
        index += 1;
    }

    if (request_body) |body| {
        const FieldType = if (body.required) body.body_type else optionalType(body.body_type);
        fields[index] = .{
            .name = "body",
            .type = FieldType,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(FieldType),
        };
    }

    return @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = &fields,
        .decls = &.{},
        .is_tuple = false,
    } });
}

fn makeParameterGroupType(comptime parameters: anytype, comptime location: Spec.ParameterLocation) type {
    const count = countParameters(parameters, location);
    var fields: [count]Type.StructField = undefined;
    var index: usize = 0;

    inline for (parameters) |resolved| {
        if (resolved.location != location) continue;
        const FieldType = if (resolved.required) resolved.field_type else optionalType(resolved.field_type);
        ensureUniqueFieldName(fields[0..index], resolved.field_name, "parameter");
        fields[index] = .{
            .name = resolved.field_name,
            .type = FieldType,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(FieldType),
        };
        index += 1;
    }

    return @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = &fields,
        .decls = &.{},
        .is_tuple = false,
    } });
}

fn collectEffectiveParameters(
    comptime files: Files,
    comptime current_file_name: []const u8,
    comptime path_item: Spec.PathItem,
    comptime operation: Spec.Operation,
    comptime context_name: []const u8,
) []const ResolvedParameter {
    const total = path_item.parameters.len + operation.parameters.len;
    comptime var parameters: [total]ResolvedParameter = undefined;
    comptime var index: usize = 0;

    inline for (path_item.parameters) |parameter_or_ref| {
        const resolved = resolveParameterOrRef(files, current_file_name, parameter_or_ref);
        const parameter = resolved.parameter;
        const selection = selectParameterSchema(parameter) orelse @compileError(std.fmt.comptimePrint(
            "Parameter '{s}' for '{s}' is missing schema support.",
            .{ parameter.name, context_name },
        ));
        parameters[index] = .{
            .field_name = zigIdentifier(parameter.name),
            .original_name = copyString(parameter.name),
            .location = parameter.location,
            .required = parameter.required,
            .encoding = selection.encoding,
            .field_type = models_mod.typeForSchemaOrRef(
                files,
                resolved.file_name,
                selection.schema.*,
                std.fmt.comptimePrint("{s}{s}", .{ context_name, parameter.name }),
            ),
        };
        index += 1;
    }

    inline for (operation.parameters) |parameter_or_ref| {
        const resolved = resolveParameterOrRef(files, current_file_name, parameter_or_ref);
        const parameter = resolved.parameter;
        const selection = selectParameterSchema(parameter) orelse @compileError(std.fmt.comptimePrint(
            "Parameter '{s}' for '{s}' is missing schema support.",
            .{ parameter.name, context_name },
        ));
        parameters[index] = .{
            .field_name = zigIdentifier(parameter.name),
            .original_name = copyString(parameter.name),
            .location = parameter.location,
            .required = parameter.required,
            .encoding = selection.encoding,
            .field_type = models_mod.typeForSchemaOrRef(
                files,
                resolved.file_name,
                selection.schema.*,
                std.fmt.comptimePrint("{s}{s}", .{ context_name, parameter.name }),
            ),
        };
        index += 1;
    }

    return parameters[0..];
}

fn resolveParameterOrRef(
    comptime files: Files,
    comptime current_file_name: []const u8,
    comptime parameter_or_ref: Spec.ParameterOrRef,
) ResolvedParameterOrigin {
    return switch (parameter_or_ref) {
        .parameter => |parameter| .{
            .file_name = current_file_name,
            .parameter = parameter,
        },
        .reference => |reference| blk: {
            const resolved = files.resolveParameterRef(current_file_name, reference.ref_path) orelse @compileError(std.fmt.comptimePrint(
                "Missing parameter reference '{s}'.",
                .{reference.ref_path},
            ));
            break :blk resolveParameterOrRef(files, resolved.file_name, resolved.parameter);
        },
    };
}

fn resolveResponseOrRef(
    comptime files: Files,
    comptime current_file_name: []const u8,
    comptime response_or_ref: Spec.ResponseOrRef,
) ResolvedResponseOrigin {
    return switch (response_or_ref) {
        .response => |response| .{
            .file_name = current_file_name,
            .response = response,
        },
        .reference => |reference| blk: {
            const resolved = files.resolveResponseRef(current_file_name, reference.ref_path) orelse @compileError(std.fmt.comptimePrint(
                "Missing response reference '{s}'.",
                .{reference.ref_path},
            ));
            break :blk resolveResponseOrRef(files, resolved.file_name, resolved.response);
        },
    };
}

fn resolveRequestBodyOrRef(
    comptime files: Files,
    comptime current_file_name: []const u8,
    comptime request_body_or_ref: Spec.RequestBodyOrRef,
) ResolvedRequestBodyOrigin {
    return switch (request_body_or_ref) {
        .request_body => |request_body| .{
            .file_name = current_file_name,
            .request_body = request_body,
        },
        .reference => |reference| blk: {
            const resolved = files.resolveRequestBodyRef(current_file_name, reference.ref_path) orelse @compileError(std.fmt.comptimePrint(
                "Missing request body reference '{s}'.",
                .{reference.ref_path},
            ));
            break :blk resolveRequestBodyOrRef(files, resolved.file_name, resolved.request_body);
        },
    };
}

fn selectParameterSchema(comptime parameter: Spec.Parameter) ?struct {
    schema: *const Spec.SchemaOrRef,
    encoding: ParameterEncoding,
} {
    if (parameter.schema) |schema| {
        return .{
            .schema = schema,
            .encoding = .scalar,
        };
    }

    inline for (parameter.content) |entry| {
        const schema = entry.value.schema orelse continue;
        return .{
            .schema = schema,
            .encoding = if (isJsonContentType(entry.name)) .json else .scalar,
        };
    }

    return null;
}

fn selectRequestBody(
    comptime lib: type,
    comptime files: Files,
    comptime current_file_name: []const u8,
    comptime request_body_or_ref: ?Spec.RequestBodyOrRef,
    comptime context_name: []const u8,
) ?SelectedRequestBody {
    const Http = embed.net.make(lib).http;
    const request_body = request_body_or_ref orelse return null;
    const resolved = resolveRequestBodyOrRef(files, current_file_name, request_body);

    inline for (resolved.request_body.content) |entry| {
        const schema = entry.value.schema orelse continue;
        if (isJsonContentType(entry.name)) {
            return .{
                .required = resolved.request_body.required,
                .body_type = models_mod.typeForSchemaOrRef(
                    files,
                    resolved.file_name,
                    schema.*,
                    std.fmt.comptimePrint("{s}Body", .{context_name}),
                ),
                .payload_kind = .json,
                .content_type = copyString(entry.name),
            };
        }

        return .{
            .required = resolved.request_body.required,
            .body_type = Http.ReadCloser,
            .payload_kind = .raw,
            .content_type = copyString(entry.name),
        };
    }

    return null;
}

fn collectResponseVariants(
    comptime files: Files,
    comptime current_file_name: []const u8,
    comptime responses: []const Spec.Named(Spec.ResponseOrRef),
    comptime context_name: []const u8,
) []const ResponseVariant {
    comptime var variants: [responses.len]ResponseVariant = undefined;
    comptime var index: usize = 0;

    inline for (responses) |named_response| {
        const resolved = resolveResponseOrRef(files, current_file_name, named_response.value);
        variants[index] = responseVariant(files, resolved.file_name, named_response.name, resolved.response, context_name, index);
        index += 1;
    }

    return variants[0..];
}

fn responseVariant(
    comptime files: Files,
    comptime current_file_name: []const u8,
    comptime status_name: []const u8,
    comptime response: Spec.Response,
    comptime context_name: []const u8,
    comptime index: usize,
) ResponseVariant {
    inline for (response.content) |entry| {
        if (!isJsonContentType(entry.name)) continue;
        const schema = entry.value.schema orelse continue;
        return .{
            .field_name = responseVariantFieldName(status_name, index),
            .status_name = copyString(status_name),
            .status_code = parseStatusCode(status_name),
            .payload_kind = .json,
            .payload_type = models_mod.typeForSchemaOrRef(
                files,
                current_file_name,
                schema.*,
                std.fmt.comptimePrint("{s}{s}Response", .{ context_name, status_name }),
            ),
        };
    }

    inline for (response.content) |entry| {
        if (isSseContentType(entry.name)) {
            return .{
                .field_name = responseVariantFieldName(status_name, index),
                .status_name = copyString(status_name),
                .status_code = parseStatusCode(status_name),
                .payload_kind = .sse,
                .payload_type = void,
            };
        }
    }

    if (response.content.len != 0) {
        return .{
            .field_name = responseVariantFieldName(status_name, index),
            .status_name = copyString(status_name),
            .status_code = parseStatusCode(status_name),
            .payload_kind = .raw,
            .payload_type = []u8,
        };
    }

    return .{
        .field_name = responseVariantFieldName(status_name, index),
        .status_name = copyString(status_name),
        .status_code = parseStatusCode(status_name),
        .payload_kind = .none,
        .payload_type = void,
    };
}

fn makeResponseType(comptime lib: type, comptime variants: anytype) type {
    if (variants.len == 0) return void;

    const Http = embed.net.make(lib).http;
    const Sse = @import("../sse.zig").make(lib);

    var enum_fields: [variants.len]Type.EnumField = undefined;
    var union_fields: [variants.len]Type.UnionField = undefined;

    inline for (variants, 0..) |variant, index| {
        const payload_type = switch (variant.payload_kind) {
            .none => void,
            .json => lib.json.Parsed(variant.payload_type),
            .raw => Http.ReadCloser,
            .sse => Sse.Reader,
        };
        ensureUniqueResponseVariantName(variants[0..index], variant.field_name, variant.status_name);

        enum_fields[index] = .{
            .name = variant.field_name,
            .value = index,
        };
        union_fields[index] = .{
            .name = variant.field_name,
            .type = payload_type,
            .alignment = @alignOf(payload_type),
        };
    }

    const Tag = @Type(.{ .@"enum" = .{
        .tag_type = u16,
        .fields = &enum_fields,
        .decls = &.{},
        .is_exhaustive = true,
    } });

    return @Type(.{ .@"union" = .{
        .layout = .auto,
        .tag_type = Tag,
        .fields = &union_fields,
        .decls = &.{},
    } });
}

fn countParameters(comptime parameters: anytype, comptime location: Spec.ParameterLocation) usize {
    comptime var total: usize = 0;
    inline for (parameters) |resolved| {
        if (resolved.location == location) total += 1;
    }
    return total;
}

fn appendBaseUrl(
    comptime lib: type,
    allocator: lib.mem.Allocator,
    builder: *lib.ArrayList(u8),
    base_url: []const u8,
    path: []const u8,
) !void {
    if (base_url.len == 0) return;
    if (base_url[base_url.len - 1] == '/' and path.len != 0 and path[0] == '/') {
        try builder.appendSlice(allocator, base_url[0 .. base_url.len - 1]);
        return;
    }
    try builder.appendSlice(allocator, base_url);
}

fn appendResolvedPath(
    comptime lib: type,
    allocator: lib.mem.Allocator,
    builder: *lib.ArrayList(u8),
    path_template: []const u8,
    comptime parameters: anytype,
    args: anytype,
) !void {
    if (!@hasField(@TypeOf(args), "path")) {
        try builder.appendSlice(allocator, path_template);
        return;
    }

    var index: usize = 0;
    while (index < path_template.len) {
        if (path_template[index] != '{') {
            try builder.append(allocator, path_template[index]);
            index += 1;
            continue;
        }

        const close_index = indexOfScalar(path_template[index..], '}') orelse return error.InvalidPathTemplate;
        const placeholder = path_template[index + 1 .. index + close_index];

        var matched = false;
        inline for (parameters) |resolved| {
            if (resolved.location != .path) continue;
            if (std.mem.eql(u8, resolved.original_name, placeholder)) {
                const rendered = try serializePathFieldValue(lib, allocator, @field(args.path, resolved.field_name), resolved.encoding);
                defer allocator.free(rendered);
                try builder.appendSlice(allocator, rendered);
                index += close_index + 1;
                matched = true;
            }
        }

        if (!matched) {
            return error.UnsupportedPathTemplate;
        }
    }
}

fn appendQueryString(
    comptime lib: type,
    allocator: lib.mem.Allocator,
    builder: *lib.ArrayList(u8),
    comptime parameters: anytype,
    args: anytype,
) !void {
    if (!@hasField(@TypeOf(args), "query")) return;

    var first = true;
    inline for (parameters) |resolved| {
        if (resolved.location != .query) continue;

        if (try appendMaybeNamedValueWithEncoding(
            lib,
            allocator,
            builder,
            resolved.original_name,
            @field(args.query, resolved.field_name),
            resolved.encoding,
            &first,
            "?",
            "&",
        )) {}
    }
}

fn appendHeaderParameters(
    comptime lib: type,
    allocator: lib.mem.Allocator,
    request: anytype,
    comptime parameters: anytype,
    args: anytype,
    owned_values: *lib.ArrayList([]const u8),
) !void {
    if (!@hasField(@TypeOf(args), "header")) return;

    inline for (parameters) |resolved| {
        if (resolved.location != .header) continue;

        const value = @field(args.header, resolved.field_name);
        switch (@typeInfo(@TypeOf(value))) {
            .optional => {
                if (value) |unwrapped| {
                    const rendered = try serializeParameterValue(lib, allocator, unwrapped, resolved.encoding);
                    try owned_values.append(allocator, rendered);
                    try request.addHeader(resolved.original_name, rendered);
                }
            },
            else => {
                const rendered = try serializeParameterValue(lib, allocator, value, resolved.encoding);
                try owned_values.append(allocator, rendered);
                try request.addHeader(resolved.original_name, rendered);
            },
        }
    }
}

fn appendCookieParameters(
    comptime lib: type,
    allocator: lib.mem.Allocator,
    request: anytype,
    comptime parameters: anytype,
    args: anytype,
    owned_values: *lib.ArrayList([]const u8),
) !void {
    if (!@hasField(@TypeOf(args), "cookie")) return;

    var builder = try lib.ArrayList(u8).initCapacity(allocator, 0);
    defer builder.deinit(allocator);

    var first = true;
    inline for (parameters) |resolved| {
        if (resolved.location != .cookie) continue;

        const value = @field(args.cookie, resolved.field_name);
        if (try appendMaybeNamedValueWithEncoding(
            lib,
            allocator,
            &builder,
            resolved.original_name,
            value,
            resolved.encoding,
            &first,
            "",
            "; ",
        )) {}
    }

    if (builder.items.len == 0) return;

    const rendered = try builder.toOwnedSlice(allocator);
    try owned_values.append(allocator, rendered);
    try request.addHeader(HttpHeaderCookieName(), rendered);
}

fn appendMaybeNamedValue(
    comptime lib: type,
    allocator: lib.mem.Allocator,
    builder: *lib.ArrayList(u8),
    name: []const u8,
    value: anytype,
    first: *bool,
) !bool {
    return appendMaybeNamedValueWithEncoding(lib, allocator, builder, name, value, .scalar, first, "?", "&");
}

fn appendMaybeNamedValueWithEncoding(
    comptime lib: type,
    allocator: lib.mem.Allocator,
    builder: *lib.ArrayList(u8),
    name: []const u8,
    value: anytype,
    comptime encoding: ParameterEncoding,
    first: *bool,
    comptime first_separator: []const u8,
    comptime separator: []const u8,
) !bool {
    switch (@typeInfo(@TypeOf(value))) {
        .optional => {
            if (value) |unwrapped| {
                try appendNamedValue(lib, allocator, builder, name, unwrapped, encoding, first, first_separator, separator);
                return true;
            }
            return false;
        },
        else => {
            try appendNamedValue(lib, allocator, builder, name, value, encoding, first, first_separator, separator);
            return true;
        },
    }
}

fn appendNamedValue(
    comptime lib: type,
    allocator: lib.mem.Allocator,
    builder: *lib.ArrayList(u8),
    name: []const u8,
    value: anytype,
    comptime encoding: ParameterEncoding,
    first: *bool,
    comptime first_separator: []const u8,
    comptime separator: []const u8,
) !void {
    const rendered = try serializeParameterValue(lib, allocator, value, encoding);
    defer allocator.free(rendered);

    try builder.appendSlice(allocator, if (first.*) first_separator else separator);
    first.* = false;
    try builder.appendSlice(allocator, name);
    try builder.append(allocator, '=');
    try builder.appendSlice(allocator, rendered);
}

fn serializeFieldValue(comptime lib: type, allocator: lib.mem.Allocator, value: anytype) ![]u8 {
    return switch (@typeInfo(@TypeOf(value))) {
        .optional => if (value) |unwrapped| serializeScalar(lib, allocator, unwrapped) else error.MissingRequiredArgument,
        else => serializeScalar(lib, allocator, value),
    };
}

fn serializePathFieldValue(
    comptime lib: type,
    allocator: lib.mem.Allocator,
    value: anytype,
    comptime encoding: ParameterEncoding,
) ![]u8 {
    return switch (@typeInfo(@TypeOf(value))) {
        .optional => if (value) |unwrapped| serializeParameterValue(lib, allocator, unwrapped, encoding) else error.MissingRequiredArgument,
        else => serializeParameterValue(lib, allocator, value, encoding),
    };
}

fn serializeParameterValue(
    comptime lib: type,
    allocator: lib.mem.Allocator,
    value: anytype,
    comptime encoding: ParameterEncoding,
) ![]u8 {
    return switch (encoding) {
        .scalar => serializeScalar(lib, allocator, value),
        .json => encodeJsonBody(lib, allocator, value),
    };
}

fn serializeScalar(comptime lib: type, allocator: lib.mem.Allocator, value: anytype) ![]u8 {
    const T = @TypeOf(value);
    return switch (@typeInfo(T)) {
        .pointer => |pointer| {
            if (pointer.size == .slice and pointer.child == u8) {
                return try allocator.dupe(u8, value);
            }
            return error.UnsupportedParameterType;
        },
        .int, .comptime_int, .float, .comptime_float => try lib.fmt.allocPrint(allocator, "{}", .{value}),
        .bool => try allocator.dupe(u8, if (value) "true" else "false"),
        else => error.UnsupportedParameterType,
    };
}

fn HttpHeaderCookieName() []const u8 {
    return "Cookie";
}

fn encodeJsonBody(comptime lib: type, allocator: lib.mem.Allocator, value: anytype) ![]u8 {
    return try lib.fmt.allocPrint(allocator, "{f}", .{lib.json.fmt(value, .{})});
}

fn readReadCloser(comptime lib: type, allocator: lib.mem.Allocator, reader: anytype) ![]u8 {
    defer reader.close();
    var list = try lib.ArrayList(u8).initCapacity(allocator, 0);
    defer list.deinit(allocator);

    var buffer: [1024]u8 = undefined;
    while (true) {
        const amount = try reader.read(&buffer);
        if (amount == 0) break;
        try list.appendSlice(allocator, buffer[0..amount]);
    }

    return try list.toOwnedSlice(allocator);
}

fn readResponseBody(comptime lib: type, allocator: lib.mem.Allocator, response: *const embed.net.make(lib).http.Response) ![]u8 {
    var body = response.body() orelse return try allocator.alloc(u8, 0);
    var list = try lib.ArrayList(u8).initCapacity(allocator, 0);
    defer list.deinit(allocator);

    var buffer: [1024]u8 = undefined;
    while (true) {
        const amount = try body.read(&buffer);
        if (amount == 0) break;
        try list.appendSlice(allocator, buffer[0..amount]);
    }

    return try list.toOwnedSlice(allocator);
}

fn decodeResponseVariant(
    comptime lib: type,
    comptime ResponseType: type,
    allocator: lib.mem.Allocator,
    response: *embed.net.make(lib).http.Response,
    comptime variant: ResponseVariant,
) !if (ResponseType == void) void else *ResponseType {
    if (ResponseType == void) return;

    const Http = embed.net.make(lib).http;
    const Sse = @import("../sse.zig").make(lib);
    const PayloadType = @FieldType(ResponseType, "value");

    switch (variant.payload_kind) {
        .none => {
            const owned = try allocator.create(ResponseType);
            owned.* = .{
                .allocator = allocator,
                .http_response = response,
                .value = @unionInit(PayloadType, variant.field_name, {}),
                .raw_empty_body = .{ .bytes = "" },
            };
            return owned;
        },
        .raw => {
            const owned = try allocator.create(ResponseType);
            owned.allocator = allocator;
            owned.http_response = response;
            owned.raw_empty_body = .{ .bytes = "" };
            const br = if (response.body()) |b| steal: {
                response.body_reader = null;
                break :steal b;
            } else Http.ReadCloser.init(&owned.raw_empty_body);
            owned.value = @unionInit(PayloadType, variant.field_name, br);
            return owned;
        },
        .sse => {
            const owned = try allocator.create(ResponseType);
            owned.allocator = allocator;
            owned.http_response = response;
            owned.raw_empty_body = .{ .bytes = "" };
            const br = if (response.body()) |b| steal: {
                response.body_reader = null;
                break :steal b;
            } else Http.ReadCloser.init(&owned.raw_empty_body);
            owned.value = @unionInit(PayloadType, variant.field_name, Sse.Reader.init(allocator, br));
            return owned;
        },
        .json => {
            const response_bytes = try readResponseBody(lib, allocator, response);
            defer allocator.free(response_bytes);

            const parsed = try lib.json.parseFromSlice(variant.payload_type, allocator, response_bytes, .{
                .allocate = .alloc_always,
            });
            const owned = try allocator.create(ResponseType);
            owned.* = .{
                .allocator = allocator,
                .http_response = response,
                .value = @unionInit(PayloadType, variant.field_name, parsed),
                .raw_empty_body = .{ .bytes = "" },
            };
            return owned;
        },
    }
}

fn responseWantsJson(comptime variants: anytype) bool {
    inline for (variants) |variant| {
        if (variant.payload_kind == .json) return true;
    }
    return false;
}

fn defaultBaseUrl(comptime spec: Spec) []const u8 {
    if (spec.servers.len == 0) return "";
    return spec.servers[0].url;
}

fn parseLocalComponentRef(comptime ref_path: []const u8, comptime prefix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, ref_path, prefix)) return null;
    return ref_path[prefix.len..];
}

fn isSuccessResponseName(comptime name: []const u8) bool {
    return name.len == 3 and name[0] == '2';
}

fn isJsonContentType(comptime name: []const u8) bool {
    const base = mediaTypeBase(name);
    return std.ascii.eqlIgnoreCase(base, "application/json") or
        std.ascii.eqlIgnoreCase(base, "text/json") or
        (base.len >= 5 and std.ascii.eqlIgnoreCase(base[base.len - 5 ..], "+json"));
}

fn isSseContentType(comptime name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(mediaTypeBase(name), "text/event-stream");
}

fn mediaTypeBase(comptime name: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, name, ';') orelse name.len;
    return std.mem.trim(u8, name[0..end], " \t");
}

fn deriveOperationName(comptime method: []const u8, comptime path: []const u8) []const u8 {
    return std.fmt.comptimePrint("{s}_{s}", .{ method, path });
}

fn responseVariantFieldName(comptime status_name: []const u8, comptime index: usize) [:0]const u8 {
    _ = index;
    if (std.mem.eql(u8, status_name, "default")) return "default";
    return zigIdentifier(std.fmt.comptimePrint("status_{s}", .{status_name}));
}

fn parseStatusCode(comptime status_name: []const u8) ?u16 {
    if (std.mem.eql(u8, status_name, "default")) return null;
    return std.fmt.parseInt(u16, status_name, 10) catch @compileError(std.fmt.comptimePrint(
        "Unsupported response status '{s}'.",
        .{status_name},
    ));
}

fn copyString(comptime value: []const u8) []const u8 {
    return std.fmt.comptimePrint("{s}", .{value});
}

fn optionalType(comptime Child: type) type {
    return @Type(.{ .optional = .{ .child = Child } });
}

fn parsedValueType(comptime ParsedType: type) type {
    return @FieldType(ParsedType, "value");
}

fn ensureUniqueOperationName(comptime operations: []const OperationRef, comptime field_name: []const u8, comptime operation_id: []const u8) void {
    inline for (operations) |operation| {
        if (std.mem.eql(u8, operation.field_name, field_name)) {
            @compileError(std.fmt.comptimePrint(
                "Duplicate client operation name '{s}' generated from '{s}'.",
                .{ field_name, operation_id },
            ));
        }
    }
}

fn ensureUniqueResponseVariantName(
    comptime variants: []const ResponseVariant,
    comptime field_name: []const u8,
    comptime status_name: []const u8,
) void {
    inline for (variants) |variant| {
        if (std.mem.eql(u8, variant.field_name, field_name)) {
            @compileError(std.fmt.comptimePrint(
                "Duplicate response variant '{s}' generated for status '{s}'.",
                .{ field_name, status_name },
            ));
        }
    }
}

fn ensureUniqueFieldName(comptime fields: []const Type.StructField, comptime field_name: []const u8, comptime kind: []const u8) void {
    inline for (fields) |field| {
        if (std.mem.eql(u8, field.name, field_name)) {
            @compileError(std.fmt.comptimePrint(
                "Duplicate {s} field '{s}' while generating client.",
                .{ kind, field_name },
            ));
        }
    }
}

fn zigIdentifier(comptime name: []const u8) [:0]const u8 {
    if (name.len == 0) return "_";

    comptime var buffer: [name.len + 1]u8 = undefined;
    comptime var index: usize = 0;

    if (!isIdentifierStart(name[0])) {
        buffer[index] = '_';
        index += 1;
    }

    inline for (name) |char| {
        buffer[index] = if (isIdentifierContinue(char)) char else '_';
        index += 1;
    }

    buffer[index] = 0;
    const rendered = std.fmt.comptimePrint("{s}\x00", .{buffer[0..index]});
    return rendered[0..index :0];
}

fn isIdentifierStart(char: u8) bool {
    return (char >= 'a' and char <= 'z') or (char >= 'A' and char <= 'Z') or char == '_';
}

fn isIdentifierContinue(char: u8) bool {
    return isIdentifierStart(char) or (char >= '0' and char <= '9');
}

fn indexOfScalar(haystack: []const u8, needle: u8) ?usize {
    for (haystack, 0..) |char, index| {
        if (char == needle) return index;
    }
    return null;
}
