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
    content_type: ?[]const u8,
};

pub fn make(comptime lib: type, comptime files: Files) type {
    @setEvalBranchQuota(300_000);

    const root = rootFile(files);
    const net = embed.net.make(lib);
    const Http = net.http;
    const ContextNs = embed.context.make(lib);
    const Models = models_mod.make(files);
    const spec_title = copyString(root.spec.info.title);
    const spec_version = copyString(root.spec.info.version);
    const operation_refs = collectOperations(files, root);
    const operation_names = blk: {
        var items: [operation_refs.len][:0]const u8 = undefined;
        for (operation_refs, 0..) |operation_ref, i| items[i] = operation_ref.field_name;
        break :blk items;
    };
    const Operations = makeOperationNamespace(lib, files, operation_refs);
    const ConfigType = makeConfigType(Operations, operation_names);

    const Shared = struct {
        allocator: lib.mem.Allocator,
        ctx: *anyopaque,
        contexts: ContextNs,
        config: ConfigType,

        pub fn serveHTTP(self: *@This(), rw: *Http.ResponseWriter, req: *Http.Request) void {
            const namespace = Operations{};

            inline for (operation_names) |operation_name| {
                const Operation = @field(namespace, operation_name);
                if (Operation.matches(req)) {
                    Operation.serve(self, rw, req);
                    return;
                }
            }

            writePlainStatus(rw, Http.status.not_found, "Not Found") catch {};
        }
    };

    return struct {
        shared: *Shared,
        http_server: Http.Server,

        const Self = @This();

        pub const models = Models;
        pub const operations = Operations{};
        pub const Config = ConfigType;
        pub const HttpServer = Http.Server;

        pub fn init(allocator: lib.mem.Allocator, ctx: anytype, config: ConfigType) !Self {
            const shared = try allocator.create(Shared);
            errdefer allocator.destroy(shared);

            var contexts = try ContextNs.init(allocator);
            errdefer contexts.deinit();

            shared.* = .{
                .allocator = allocator,
                .ctx = opaquePtr(ctx),
                .contexts = contexts,
                .config = config,
            };

            var http_server = try Http.Server.init(allocator, .{
                .handler = Http.Handler.init(shared),
            });
            errdefer http_server.deinit();

            return .{
                .shared = shared,
                .http_server = http_server,
            };
        }

        pub fn deinit(self: *Self) void {
            const allocator = self.shared.allocator;
            self.http_server.deinit();
            self.shared.contexts.deinit();
            allocator.destroy(self.shared);
            self.* = undefined;
        }

        pub fn serve(self: *Self, listener: embed.net.Listener) anyerror!void {
            return self.http_server.serve(listener);
        }

        pub fn close(self: *Self) void {
            self.http_server.close();
        }

        pub fn handler(self: *Self) Http.Handler {
            return Http.Handler.init(self.shared);
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

fn makeOperationNamespace(
    comptime lib: type,
    comptime files: Files,
    comptime operation_refs: []const OperationRef,
) type {
    var fields: [operation_refs.len]Type.StructField = undefined;

    inline for (operation_refs, 0..) |operation_ref, index| {
        const Operation = OperationType(lib, files, operation_ref);
        fields[index] = .{
            .name = operation_ref.field_name,
            .type = type,
            .default_value_ptr = defaultValuePtr(type, Operation),
            .is_comptime = true,
            .alignment = 1,
        };
    }

    return @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = &fields,
        .decls = &.{},
        .is_tuple = false,
    } });
}

fn makeConfigType(comptime Operations: type, comptime operation_names: anytype) type {
    var fields: [operation_names.len]Type.StructField = undefined;

    inline for (operation_names, 0..) |operation_name, index| {
        const Operation = @field(Operations{}, operation_name);
        const FieldType = ?Operation.Handler;
        fields[index] = .{
            .name = operation_name,
            .type = FieldType,
            .default_value_ptr = defaultValuePtr(FieldType, null),
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

fn OperationType(
    comptime lib: type,
    comptime files: Files,
    comptime operation_ref: OperationRef,
) type {
    const net = embed.net.make(lib);
    const Http = net.http;
    const Context = embed.context.Context;
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
    const response_variants_slice = collectResponseVariants(files, operation_ref.file_name, operation_ref.operation.responses, operation_ref.field_name);
    const response_variants = blk: {
        var items: [response_variants_slice.len]ResponseVariant = undefined;
        for (response_variants_slice, 0..) |variant, i| items[i] = variant;
        break :blk items;
    };
    const ArgsType = makeArgsType(parameters, request_body);
    const ResponseType = makeServerResponseType(lib, response_variants);
    const method = copyString(operation_ref.method);
    const path = copyString(operation_ref.path);
    const handler_field_name = operation_ref.field_name;

    return struct {
        pub const Args = ArgsType;
        pub const Response = ResponseType;
        /// `allocator` is a request-scoped arena (reset after the response is written). Raw request bodies are `http.ReadCloser`; handlers must read and `close` them.
        pub const Handler = *const fn (ptr: *anyopaque, ctx: Context, allocator: lib.mem.Allocator, args: ArgsType) anyerror!ResponseType;

        pub fn matches(req: *Http.Request) bool {
            return std.mem.eql(u8, req.effectiveMethod(), method) and pathMatchesTemplate(path, req.url.path);
        }

        pub fn serve(shared: anytype, rw: *Http.ResponseWriter, req: *Http.Request) void {
            const handler = @field(shared.config, handler_field_name) orelse {
                writePlainStatus(rw, Http.status.not_implemented, "Not Implemented") catch {};
                return;
            };
            const request_ctx = req.context() orelse shared.contexts.background();
            const RawRequestBodyGuard = struct {
                inner: Http.ReadCloser,
                drained: bool = false,
                closed: bool = false,

                fn init(inner: Http.ReadCloser) @This() {
                    return .{ .inner = inner };
                }

                pub fn read(self: *@This(), buffer: []u8) anyerror!usize {
                    const n = try self.inner.read(buffer);
                    if (n == 0) self.drained = true;
                    return n;
                }

                pub fn close(self: *@This()) void {
                    if (self.closed) return;
                    self.closed = true;
                    if (self.drained) return;

                    var buf: [1024]u8 = undefined;
                    while (true) {
                        const n = self.inner.read(&buf) catch break;
                        if (n == 0) {
                            self.drained = true;
                            break;
                        }
                    }
                }
            };

            var args: ArgsType = undefined;
            parseParameterGroups(shared.allocator, req, &args) catch {
                writePlainStatus(rw, Http.status.bad_request, "Bad Request") catch {};
                return;
            };

            var temp_arena = std.heap.ArenaAllocator.init(shared.allocator);
            defer temp_arena.deinit();
            const temp_allocator = temp_arena.allocator();
            var raw_request_body_guard: RawRequestBodyGuard = undefined;
            var has_raw_request_body_guard = false;
            defer if (has_raw_request_body_guard) raw_request_body_guard.close();

            if (request_body) |body| {
                switch (body.payload_kind) {
                    .json => {
                        if (req.body()) |reader| {
                            const body_bytes = readBody(lib, temp_allocator, reader) catch {
                                writePlainStatus(rw, Http.status.bad_request, "Bad Request") catch {};
                                return;
                            };
                            const parsed = std.json.parseFromSliceLeaky(body.body_type, temp_allocator, body_bytes, .{}) catch {
                                writePlainStatus(rw, Http.status.bad_request, "Bad Request") catch {};
                                return;
                            };
                            @field(args, "body") = parsed;
                        } else {
                            if (body.required) {
                                writePlainStatus(rw, Http.status.bad_request, "Bad Request") catch {};
                                return;
                            }
                            @field(args, "body") = null;
                        }
                    },
                    .raw => {
                        if (req.body_reader) |stolen| {
                            req.body_reader = null;
                            raw_request_body_guard = RawRequestBodyGuard.init(stolen);
                            has_raw_request_body_guard = true;
                            @field(args, "body") = Http.ReadCloser.init(&raw_request_body_guard);
                        } else {
                            if (body.required) {
                                writePlainStatus(rw, Http.status.bad_request, "Bad Request") catch {};
                                return;
                            }
                            @field(args, "body") = null;
                        }
                    },
                }
            }

            const response_value = handler(shared.ctx, request_ctx, temp_allocator, args) catch {
                writePlainStatus(rw, Http.status.internal_server_error, "Internal Server Error") catch {};
                return;
            };

            writeResponse(shared.allocator, rw, response_value) catch {
                writePlainStatus(rw, Http.status.internal_server_error, "Internal Server Error") catch {};
            };
        }

        fn parseParameterGroups(
            allocator: lib.mem.Allocator,
            req: *Http.Request,
            out_args: *ArgsType,
        ) !void {
            if (@hasField(ArgsType, "path")) {
                @field(out_args.*, "path") = try parseParameterGroup(ArgsType, "path", allocator, req, runtime_parameters, path);
            }

            if (@hasField(ArgsType, "query")) {
                @field(out_args.*, "query") = try parseParameterGroup(ArgsType, "query", allocator, req, runtime_parameters, path);
            }

            if (@hasField(ArgsType, "header")) {
                @field(out_args.*, "header") = try parseParameterGroup(ArgsType, "header", allocator, req, runtime_parameters, path);
            }

            if (@hasField(ArgsType, "cookie")) {
                @field(out_args.*, "cookie") = try parseParameterGroup(ArgsType, "cookie", allocator, req, runtime_parameters, path);
            }
        }

        fn writeResponse(allocator: lib.mem.Allocator, rw: *Http.ResponseWriter, response_value: ResponseType) !void {
            const Sse = @import("../sse.zig").make(lib);
            switch (response_value) {
                inline else => |payload, tag| {
                    const variant = comptime responseVariantByName(response_variants, @tagName(tag));
                    const status_code = variant.status_code orelse Http.status.internal_server_error;
                    switch (variant.payload_kind) {
                        .none => try rw.writeHeader(status_code),
                        .raw => {
                            if (variant.content_type) |content_type| {
                                try rw.setHeader(Http.Header.content_type, content_type);
                            }
                            var len_buf: [32]u8 = undefined;
                            const len_text = try std.fmt.bufPrint(&len_buf, "{d}", .{payload.len});
                            try rw.setHeader(Http.Header.content_length, len_text);
                            try rw.writeHeader(status_code);
                            try writeAll(rw, payload);
                        },
                        .sse => {
                            var writer = Sse.Writer.init(rw);
                            try writer.beginWithContentType(status_code, variant.content_type orelse "text/event-stream");
                            try payload.send(payload.ptr, &writer);
                            try writer.flush();
                        },
                        .json => {
                            const encoded = try encodeJsonBody(lib, allocator, payload);
                            defer allocator.free(encoded);
                            try rw.setHeader(Http.Header.content_type, variant.content_type orelse "application/json");
                            try rw.writeHeader(status_code);
                            try writeAll(rw, encoded);
                        },
                    }
                },
            }
        }
    };
}

fn rootFile(comptime files: Files) RootFile {
    if (files.items.len == 0) {
        @compileError("server.make requires at least one OpenAPI file.");
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

fn makeArgsType(comptime parameters: anytype, comptime request_body: ?SelectedRequestBody) type {
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
        const schema = entry.value.schema orelse continue;
        if (isJsonContentType(entry.name)) {
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
                .content_type = copyString(entry.name),
            };
        }
    }

    inline for (response.content) |entry| {
        if (isSseContentType(entry.name)) {
            return .{
                .field_name = responseVariantFieldName(status_name, index),
                .status_name = copyString(status_name),
                .status_code = parseStatusCode(status_name),
                .payload_kind = .sse,
                .payload_type = void,
                .content_type = copyString(entry.name),
            };
        }
    }

    if (response.content.len != 0) {
        return .{
            .field_name = responseVariantFieldName(status_name, index),
            .status_name = copyString(status_name),
            .status_code = parseStatusCode(status_name),
            .payload_kind = .raw,
            .payload_type = []const u8,
            .content_type = copyString(response.content[0].name),
        };
    }

    return .{
        .field_name = responseVariantFieldName(status_name, index),
        .status_name = copyString(status_name),
        .status_code = parseStatusCode(status_name),
        .payload_kind = .none,
        .payload_type = void,
        .content_type = null,
    };
}

fn makeServerResponseType(comptime lib: type, comptime variants: anytype) type {
    if (variants.len == 0) return void;

    const Sse = @import("../sse.zig").make(lib);
    var enum_fields: [variants.len]Type.EnumField = undefined;
    var union_fields: [variants.len]Type.UnionField = undefined;

    inline for (variants, 0..) |variant, index| {
        ensureUniqueResponseVariantName(variants[0..index], variant.field_name, variant.status_name);
        const payload_type = switch (variant.payload_kind) {
            .none => void,
            .json => variant.payload_type,
            .raw => variant.payload_type,
            .sse => Sse.Stream,
        };
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

fn parseParameterGroup(
    comptime ArgsType: type,
    comptime field_name: []const u8,
    allocator: anytype,
    req: anytype,
    comptime parameters: anytype,
    comptime path_template: []const u8,
) !@FieldType(ArgsType, field_name) {
    const GroupType = @FieldType(ArgsType, field_name);
    var group: GroupType = undefined;
    const location: Spec.ParameterLocation = switch (field_name[0]) {
        'p' => .path,
        'q' => .query,
        'h' => .header,
        'c' => .cookie,
        else => @compileError("Unsupported parameter group."),
    };

    inline for (parameters) |resolved| {
        if (resolved.location != location) continue;
        const lookup = switch (location) {
            .path => lookupPathParam(req.url.path, path_template, resolved.original_name),
            .query => lookupQueryValue(req.url.raw_query, resolved.original_name),
            .header => lookupHeaderValue(req.header, resolved.original_name),
            .cookie => lookupCookieValue(req.header, resolved.original_name),
        };

        @field(group, resolved.field_name) = try parseArgumentValue(@FieldType(GroupType, resolved.field_name), lookup, allocator, resolved.encoding);
    }

    return group;
}

fn pathMatchesTemplate(template: []const u8, actual_path: []const u8) bool {
    var template_it = segmentIterator(template);
    var actual_it = segmentIterator(actual_path);

    while (true) {
        const template_segment = template_it.next();
        const actual_segment = actual_it.next();

        if (template_segment == null or actual_segment == null) {
            return template_segment == null and actual_segment == null;
        }

        if (isPathPlaceholder(template_segment.?)) continue;
        if (!std.mem.eql(u8, template_segment.?, actual_segment.?)) return false;
    }
}

fn lookupPathParam(actual_path: []const u8, template: []const u8, target_name: []const u8) ?[]const u8 {
    var template_it = segmentIterator(template);
    var actual_it = segmentIterator(actual_path);

    while (true) {
        const template_segment = template_it.next() orelse return null;
        const actual_segment = actual_it.next() orelse return null;

        if (!isPathPlaceholder(template_segment)) {
            if (!std.mem.eql(u8, template_segment, actual_segment)) return null;
            continue;
        }

        const placeholder = template_segment[1 .. template_segment.len - 1];
        if (std.mem.eql(u8, placeholder, target_name)) return actual_segment;
    }
}

fn segmentIterator(input: []const u8) SegmentIterator {
    return .{ .input = input };
}

const SegmentIterator = struct {
    input: []const u8,
    index: usize = 0,

    fn next(self: *@This()) ?[]const u8 {
        while (self.index < self.input.len and self.input[self.index] == '/') self.index += 1;
        if (self.index >= self.input.len) return null;

        const start = self.index;
        while (self.index < self.input.len and self.input[self.index] != '/') self.index += 1;
        return self.input[start..self.index];
    }
};

fn isPathPlaceholder(segment: []const u8) bool {
    return segment.len >= 2 and segment[0] == '{' and segment[segment.len - 1] == '}';
}

fn lookupQueryValue(raw_query: []const u8, name: []const u8) ?[]const u8 {
    var start: usize = 0;
    while (start <= raw_query.len) {
        const end = std.mem.indexOfScalarPos(u8, raw_query, start, '&') orelse raw_query.len;
        const pair = raw_query[start..end];
        if (pair.len != 0) {
            const equal = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
            const pair_name = pair[0..equal];
            const pair_value = if (equal < pair.len) pair[equal + 1 ..] else "";
            if (std.mem.eql(u8, pair_name, name)) return pair_value;
        }
        if (end == raw_query.len) break;
        start = end + 1;
    }
    return null;
}

fn lookupHeaderValue(headers: anytype, name: []const u8) ?[]const u8 {
    for (headers) |header| {
        if (header.is(name)) return header.value;
    }
    return null;
}

fn lookupCookieValue(headers: anytype, name: []const u8) ?[]const u8 {
    const raw = lookupHeaderValue(headers, "Cookie") orelse return null;
    var start: usize = 0;
    while (start < raw.len) {
        while (start < raw.len and (raw[start] == ' ' or raw[start] == ';')) start += 1;
        if (start >= raw.len) break;
        const end = std.mem.indexOfScalarPos(u8, raw, start, ';') orelse raw.len;
        const pair = raw[start..end];
        const equal = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        const pair_name = pair[0..equal];
        const pair_value = if (equal < pair.len) pair[equal + 1 ..] else "";
        if (std.mem.eql(u8, pair_name, name)) return pair_value;
        start = end + 1;
    }
    return null;
}

fn parseArgumentValue(comptime T: type, value: ?[]const u8, allocator: anytype, comptime encoding: ParameterEncoding) !T {
    switch (@typeInfo(T)) {
        .optional => |optional| {
            const text = value orelse return null;
            return try parseArgumentValue(optional.child, text, allocator, encoding);
        },
        .pointer => |pointer| {
            if (pointer.size == .slice and pointer.child == u8) {
                return value orelse error.MissingRequiredParameter;
            }
            return error.UnsupportedParameterType;
        },
        .@"struct", .@"union", .array => {
            const text = value orelse return error.MissingRequiredParameter;
            return switch (encoding) {
                .json => try std.json.parseFromSliceLeaky(T, allocator, text, .{}),
                .scalar => error.UnsupportedParameterType,
            };
        },
        .int => {
            const text = value orelse return error.MissingRequiredParameter;
            return try std.fmt.parseInt(T, text, 10);
        },
        .float => {
            const text = value orelse return error.MissingRequiredParameter;
            return try std.fmt.parseFloat(T, text);
        },
        .bool => {
            const text = value orelse return error.MissingRequiredParameter;
            if (std.mem.eql(u8, text, "true")) return true;
            if (std.mem.eql(u8, text, "false")) return false;
            return error.InvalidBoolean;
        },
        else => return error.UnsupportedParameterType,
    }
}

fn readBody(comptime lib: type, allocator: lib.mem.Allocator, reader: anytype) ![]u8 {
    var list = try lib.ArrayList(u8).initCapacity(allocator, 0);
    defer list.deinit(allocator);

    var buffer: [1024]u8 = undefined;
    var body_reader = reader;
    while (true) {
        const amount = try body_reader.read(&buffer);
        if (amount == 0) break;
        try list.appendSlice(allocator, buffer[0..amount]);
    }

    return try list.toOwnedSlice(allocator);
}

fn encodeJsonBody(comptime lib: type, allocator: lib.mem.Allocator, value: anytype) ![]u8 {
    return try lib.fmt.allocPrint(allocator, "{f}", .{lib.json.fmt(value, .{})});
}

fn writePlainStatus(rw: anytype, status_code: u16, body: []const u8) !void {
    try rw.setHeader("Content-Type", "text/plain");
    try rw.writeHeader(status_code);
    if (body.len != 0) _ = try rw.write(body);
}

fn defaultValuePtr(comptime T: type, comptime value: T) *const anyopaque {
    const Holder = struct {
        const stored: T = value;
    };
    return @as(*const anyopaque, @ptrCast(&Holder.stored));
}

fn opaquePtr(pointer: anytype) *anyopaque {
    const Ptr = @TypeOf(pointer);
    const info = @typeInfo(Ptr);
    if (info != .pointer or info.pointer.size != .one) {
        @compileError("server.init expects a single-item pointer for ctx.");
    }
    return @ptrCast(pointer);
}

fn parseLocalComponentRef(comptime ref_path: []const u8, comptime prefix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, ref_path, prefix)) return null;
    return ref_path[prefix.len..];
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

fn writeAll(writer: anytype, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        offset += try writer.write(bytes[offset..]);
    }
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

fn optionalType(comptime Child: type) type {
    return @Type(.{ .optional = .{ .child = Child } });
}

fn copyString(comptime value: []const u8) []const u8 {
    return std.fmt.comptimePrint("{s}", .{value});
}

fn ensureUniqueOperationName(comptime operations: []const OperationRef, comptime field_name: []const u8, comptime operation_id: []const u8) void {
    inline for (operations) |operation| {
        if (std.mem.eql(u8, operation.field_name, field_name)) {
            @compileError(std.fmt.comptimePrint(
                "Duplicate server operation name '{s}' generated from '{s}'.",
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
                "Duplicate server response variant '{s}' generated for status '{s}'.",
                .{ field_name, status_name },
            ));
        }
    }
}

fn responseVariantByName(comptime variants: anytype, comptime field_name: []const u8) ResponseVariant {
    inline for (variants) |variant| {
        if (std.mem.eql(u8, variant.field_name, field_name)) return variant;
    }
    @compileError(std.fmt.comptimePrint("Missing response variant '{s}'.", .{field_name}));
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
