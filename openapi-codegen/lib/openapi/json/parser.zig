const std = @import("std");
const Spec = @import("../Spec.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;

pub fn parseComptime(comptime document: []const u8) Spec {
    @setEvalBranchQuota(5_000_000);

    var parser: ComptimeParser = .{
        .source = document,
    };

    return parser.parseSpec() catch |err| {
        @compileError(std.fmt.comptimePrint(
            "Failed to parse JSON document at comptime: {s}",
            .{@errorName(err)},
        ));
    };
}

pub fn parse(allocator: Allocator, document: []const u8) !Spec {
    const parsed = try std.json.parseFromSlice(Value, allocator, document, .{
        .allocate = .alloc_if_needed,
    });
    defer parsed.deinit();

    return try parseSpec(allocator, parsed.value);
}

fn parseSpec(allocator: Allocator, value: Value) !Spec {
    const object = try expectObject(value);

    return .{
        .openapi = try requiredString(allocator, object, "openapi"),
        .info = if (object.get("info")) |info| try parseInfo(allocator, info) else .{},
        .servers = try parseArray(Spec.Server, allocator, object.get("servers"), parseServer),
        .paths = try parseNamedMap(Spec.PathItemOrRef, allocator, object.get("paths"), parsePathItemOrRef),
        .components = if (object.get("components")) |components| try parseComponents(allocator, components) else null,
        .security = try parseArray(Spec.SecurityRequirement, allocator, object.get("security"), parseSecurityRequirement),
        .tags = try parseArray(Spec.Tag, allocator, object.get("tags"), parseTag),
        .external_docs = if (object.get("externalDocs")) |docs| try parseExternalDocumentation(allocator, docs) else null,
    };
}

fn parseInfo(allocator: Allocator, value: Value) !Spec.Info {
    const object = try expectObject(value);
    return .{
        .title = try optionalString(allocator, object, "title") orelse "",
        .summary = try optionalString(allocator, object, "summary"),
        .description = try optionalString(allocator, object, "description"),
        .terms_of_service = try optionalString(allocator, object, "termsOfService"),
        .contact = if (object.get("contact")) |contact| try parseContact(allocator, contact) else null,
        .license = if (object.get("license")) |license| try parseLicense(allocator, license) else null,
        .version = try optionalString(allocator, object, "version") orelse "",
    };
}

fn parseContact(allocator: Allocator, value: Value) !Spec.Contact {
    const object = try expectObject(value);
    return .{
        .name = try optionalString(allocator, object, "name"),
        .url = try optionalString(allocator, object, "url"),
        .email = try optionalString(allocator, object, "email"),
    };
}

fn parseLicense(allocator: Allocator, value: Value) !Spec.License {
    const object = try expectObject(value);
    return .{
        .name = try requiredString(allocator, object, "name"),
        .identifier = try optionalString(allocator, object, "identifier"),
        .url = try optionalString(allocator, object, "url"),
    };
}

fn parseExternalDocumentation(allocator: Allocator, value: Value) !Spec.ExternalDocumentation {
    const object = try expectObject(value);
    return .{
        .description = try optionalString(allocator, object, "description"),
        .url = try requiredString(allocator, object, "url"),
    };
}

fn parseServer(allocator: Allocator, value: Value) !Spec.Server {
    const object = try expectObject(value);
    return .{
        .url = try requiredString(allocator, object, "url"),
        .description = try optionalString(allocator, object, "description"),
        .variables = try parseNamedMap(Spec.ServerVariable, allocator, object.get("variables"), parseServerVariable),
    };
}

fn parseServerVariable(allocator: Allocator, value: Value) !Spec.ServerVariable {
    const object = try expectObject(value);
    return .{
        .enum_values = try parseStringArray(allocator, object.get("enum")),
        .default_value = try requiredString(allocator, object, "default"),
        .description = try optionalString(allocator, object, "description"),
    };
}

fn parseTag(allocator: Allocator, value: Value) !Spec.Tag {
    const object = try expectObject(value);
    return .{
        .name = try requiredString(allocator, object, "name"),
        .description = try optionalString(allocator, object, "description"),
        .external_docs = if (object.get("externalDocs")) |docs| try parseExternalDocumentation(allocator, docs) else null,
    };
}

fn parseComponents(allocator: Allocator, value: Value) !Spec.Components {
    const object = try expectObject(value);
    return .{
        .schemas = try parseNamedMap(Spec.SchemaOrRef, allocator, object.get("schemas"), parseSchemaOrRef),
        .responses = try parseNamedMap(Spec.ResponseOrRef, allocator, object.get("responses"), parseResponseOrRef),
        .parameters = try parseNamedMap(Spec.ParameterOrRef, allocator, object.get("parameters"), parseParameterOrRef),
        .examples = try parseNamedMap(Spec.ExampleOrRef, allocator, object.get("examples"), parseExampleOrRef),
        .request_bodies = try parseNamedMap(Spec.RequestBodyOrRef, allocator, object.get("requestBodies"), parseRequestBodyOrRef),
        .headers = try parseNamedMap(Spec.HeaderOrRef, allocator, object.get("headers"), parseHeaderOrRef),
        .security_schemes = try parseNamedMap(Spec.SecuritySchemeOrRef, allocator, object.get("securitySchemes"), parseSecuritySchemeOrRef),
        .links = try parseNamedMap(Spec.LinkOrRef, allocator, object.get("links"), parseLinkOrRef),
        .callbacks = try parseNamedMap(Spec.CallbackOrRef, allocator, object.get("callbacks"), parseCallbackOrRef),
    };
}

fn parsePathItemOrRef(allocator: Allocator, value: Value) !Spec.PathItemOrRef {
    const object = try expectObject(value);
    if (isReferenceObject(object)) {
        return .{ .reference = try parseReferenceObject(allocator, object) };
    }
    return .{ .path_item = try parsePathItem(allocator, value) };
}

fn parsePathItem(allocator: Allocator, value: Value) !Spec.PathItem {
    const object = try expectObject(value);
    return .{
        .summary = try optionalString(allocator, object, "summary"),
        .description = try optionalString(allocator, object, "description"),
        .get = if (object.get("get")) |item| try parseOperation(allocator, item) else null,
        .put = if (object.get("put")) |item| try parseOperation(allocator, item) else null,
        .post = if (object.get("post")) |item| try parseOperation(allocator, item) else null,
        .delete = if (object.get("delete")) |item| try parseOperation(allocator, item) else null,
        .options = if (object.get("options")) |item| try parseOperation(allocator, item) else null,
        .head = if (object.get("head")) |item| try parseOperation(allocator, item) else null,
        .patch = if (object.get("patch")) |item| try parseOperation(allocator, item) else null,
        .trace = if (object.get("trace")) |item| try parseOperation(allocator, item) else null,
        .servers = try parseArray(Spec.Server, allocator, object.get("servers"), parseServer),
        .parameters = try parseArray(Spec.ParameterOrRef, allocator, object.get("parameters"), parseParameterOrRef),
    };
}

fn parseOperation(allocator: Allocator, value: Value) !Spec.Operation {
    const object = try expectObject(value);
    return .{
        .tags = try parseStringArray(allocator, object.get("tags")),
        .summary = try optionalString(allocator, object, "summary"),
        .description = try optionalString(allocator, object, "description"),
        .external_docs = if (object.get("externalDocs")) |docs| try parseExternalDocumentation(allocator, docs) else null,
        .operation_id = try optionalString(allocator, object, "operationId"),
        .parameters = try parseArray(Spec.ParameterOrRef, allocator, object.get("parameters"), parseParameterOrRef),
        .request_body = if (object.get("requestBody")) |body| try parseRequestBodyOrRef(allocator, body) else null,
        .responses = try parseNamedMap(Spec.ResponseOrRef, allocator, object.get("responses"), parseResponseOrRef),
        .callbacks = try parseNamedMap(Spec.CallbackOrRef, allocator, object.get("callbacks"), parseCallbackOrRef),
        .deprecated = try optionalBool(object, "deprecated") orelse false,
        .security = try parseArray(Spec.SecurityRequirement, allocator, object.get("security"), parseSecurityRequirement),
        .servers = try parseArray(Spec.Server, allocator, object.get("servers"), parseServer),
    };
}

fn parseParameterOrRef(allocator: Allocator, value: Value) !Spec.ParameterOrRef {
    const object = try expectObject(value);
    if (isReferenceObject(object)) {
        return .{ .reference = try parseReferenceObject(allocator, object) };
    }
    return .{ .parameter = try parseParameter(allocator, value) };
}

fn parseParameter(allocator: Allocator, value: Value) !Spec.Parameter {
    const object = try expectObject(value);
    return .{
        .name = try requiredString(allocator, object, "name"),
        .location = try parseParameterLocation(object.get("in") orelse return error.MissingField),
        .description = try optionalString(allocator, object, "description"),
        .required = try optionalBool(object, "required") orelse false,
        .deprecated = try optionalBool(object, "deprecated") orelse false,
        .allow_empty_value = try optionalBool(object, "allowEmptyValue") orelse false,
        .style = try optionalString(allocator, object, "style"),
        .explode = try optionalBool(object, "explode"),
        .allow_reserved = try optionalBool(object, "allowReserved") orelse false,
        .schema = if (object.get("schema")) |schema| try allocOne(Spec.SchemaOrRef, allocator, try parseSchemaOrRef(allocator, schema)) else null,
        .example = if (object.get("example")) |example| try parseLiteral(allocator, example) else null,
        .content = try parseNamedMap(Spec.MediaType, allocator, object.get("content"), parseMediaType),
    };
}

fn parseRequestBodyOrRef(allocator: Allocator, value: Value) !Spec.RequestBodyOrRef {
    const object = try expectObject(value);
    if (isReferenceObject(object)) {
        return .{ .reference = try parseReferenceObject(allocator, object) };
    }
    return .{ .request_body = try parseRequestBody(allocator, value) };
}

fn parseRequestBody(allocator: Allocator, value: Value) !Spec.RequestBody {
    const object = try expectObject(value);
    return .{
        .description = try optionalString(allocator, object, "description"),
        .content = try parseNamedMap(Spec.MediaType, allocator, object.get("content"), parseMediaType),
        .required = try optionalBool(object, "required") orelse false,
    };
}

fn parseResponseOrRef(allocator: Allocator, value: Value) !Spec.ResponseOrRef {
    const object = try expectObject(value);
    if (isReferenceObject(object)) {
        return .{ .reference = try parseReferenceObject(allocator, object) };
    }
    return .{ .response = try parseResponse(allocator, value) };
}

fn parseResponse(allocator: Allocator, value: Value) !Spec.Response {
    const object = try expectObject(value);
    return .{
        .description = try optionalString(allocator, object, "description") orelse "",
        .headers = try parseNamedMap(Spec.HeaderOrRef, allocator, object.get("headers"), parseHeaderOrRef),
        .content = try parseNamedMap(Spec.MediaType, allocator, object.get("content"), parseMediaType),
        .links = try parseNamedMap(Spec.LinkOrRef, allocator, object.get("links"), parseLinkOrRef),
    };
}

fn parseHeaderOrRef(allocator: Allocator, value: Value) !Spec.HeaderOrRef {
    const object = try expectObject(value);
    if (isReferenceObject(object)) {
        return .{ .reference = try parseReferenceObject(allocator, object) };
    }
    return .{ .header = try parseHeader(allocator, value) };
}

fn parseHeader(allocator: Allocator, value: Value) !Spec.Header {
    const object = try expectObject(value);
    return .{
        .description = try optionalString(allocator, object, "description"),
        .required = try optionalBool(object, "required") orelse false,
        .deprecated = try optionalBool(object, "deprecated") orelse false,
        .allow_empty_value = try optionalBool(object, "allowEmptyValue") orelse false,
        .style = try optionalString(allocator, object, "style"),
        .explode = try optionalBool(object, "explode"),
        .allow_reserved = try optionalBool(object, "allowReserved") orelse false,
        .schema = if (object.get("schema")) |schema| try allocOne(Spec.SchemaOrRef, allocator, try parseSchemaOrRef(allocator, schema)) else null,
        .example = if (object.get("example")) |example| try parseLiteral(allocator, example) else null,
        .content = try parseNamedMap(Spec.MediaType, allocator, object.get("content"), parseMediaType),
    };
}

fn parseMediaType(allocator: Allocator, value: Value) !Spec.MediaType {
    const object = try expectObject(value);
    return .{
        .schema = if (object.get("schema")) |schema| try allocOne(Spec.SchemaOrRef, allocator, try parseSchemaOrRef(allocator, schema)) else null,
        .example = if (object.get("example")) |example| try parseLiteral(allocator, example) else null,
        .examples = try parseNamedMap(Spec.ExampleOrRef, allocator, object.get("examples"), parseExampleOrRef),
        .encoding = try parseNamedMap(Spec.Encoding, allocator, object.get("encoding"), parseEncoding),
    };
}

fn parseEncoding(allocator: Allocator, value: Value) !Spec.Encoding {
    const object = try expectObject(value);
    return .{
        .content_type = try optionalString(allocator, object, "contentType"),
        .headers = try parseNamedMap(Spec.HeaderOrRef, allocator, object.get("headers"), parseHeaderOrRef),
        .style = try optionalString(allocator, object, "style"),
        .explode = try optionalBool(object, "explode"),
        .allow_reserved = try optionalBool(object, "allowReserved") orelse false,
    };
}

fn parseSchemaOrRef(allocator: Allocator, value: Value) anyerror!Spec.SchemaOrRef {
    const object = try expectObject(value);
    if (isReferenceObject(object)) {
        return .{ .reference = try parseReferenceObject(allocator, object) };
    }
    return .{ .schema = try parseSchema(allocator, value) };
}

fn parseSchema(allocator: Allocator, value: Value) anyerror!Spec.Schema {
    const object = try expectObject(value);
    return .{
        .title = try optionalString(allocator, object, "title"),
        .multiple_of = try optionalNumber(object, "multipleOf"),
        .maximum = try optionalNumber(object, "maximum"),
        .exclusive_maximum = try optionalBool(object, "exclusiveMaximum"),
        .minimum = try optionalNumber(object, "minimum"),
        .exclusive_minimum = try optionalBool(object, "exclusiveMinimum"),
        .max_length = try optionalU64(object, "maxLength"),
        .min_length = try optionalU64(object, "minLength"),
        .pattern = try optionalString(allocator, object, "pattern"),
        .max_items = try optionalU64(object, "maxItems"),
        .min_items = try optionalU64(object, "minItems"),
        .unique_items = try optionalBool(object, "uniqueItems") orelse false,
        .max_properties = try optionalU64(object, "maxProperties"),
        .min_properties = try optionalU64(object, "minProperties"),
        .required = try parseStringArray(allocator, object.get("required")),
        .enum_values = try parseLiteralArray(allocator, object.get("enum")),
        .schema_type = try optionalString(allocator, object, "type"),
        .all_of = try parseArray(Spec.SchemaOrRef, allocator, object.get("allOf"), parseSchemaOrRef),
        .one_of = try parseArray(Spec.SchemaOrRef, allocator, object.get("oneOf"), parseSchemaOrRef),
        .any_of = try parseArray(Spec.SchemaOrRef, allocator, object.get("anyOf"), parseSchemaOrRef),
        .items = if (object.get("items")) |items| try allocOne(Spec.SchemaOrRef, allocator, try parseSchemaOrRef(allocator, items)) else null,
        .properties = try parseNamedMap(Spec.SchemaOrRef, allocator, object.get("properties"), parseSchemaOrRef),
        .additional_properties = if (object.get("additionalProperties")) |additional_properties| try parseAdditionalProperties(allocator, additional_properties) else null,
        .discriminator = if (object.get("discriminator")) |discriminator| try parseDiscriminator(allocator, discriminator) else null,
        .description = try optionalString(allocator, object, "description"),
        .format = try optionalString(allocator, object, "format"),
        .default = if (object.get("default")) |default_value| try parseLiteral(allocator, default_value) else null,
        .nullable = try optionalBool(object, "nullable") orelse false,
        .read_only = try optionalBool(object, "readOnly") orelse false,
        .write_only = try optionalBool(object, "writeOnly") orelse false,
        .example = if (object.get("example")) |example| try parseLiteral(allocator, example) else null,
        .deprecated = try optionalBool(object, "deprecated") orelse false,
        .xml = if (object.get("xml")) |xml| try parseXml(allocator, xml) else null,
    };
}

fn parseAdditionalProperties(allocator: Allocator, value: Value) anyerror!Spec.AdditionalProperties {
    return switch (value) {
        .bool => |bool_value| .{ .boolean = bool_value },
        .object => .{ .schema = try allocOne(Spec.SchemaOrRef, allocator, try parseSchemaOrRef(allocator, value)) },
        else => error.ExpectedObject,
    };
}

fn parseDiscriminator(allocator: Allocator, value: Value) !Spec.Discriminator {
    const object = try expectObject(value);
    return .{
        .property_name = try requiredString(allocator, object, "propertyName"),
        .mapping = try parseNamedMap([]const u8, allocator, object.get("mapping"), parseStringItem),
    };
}

fn parseXml(allocator: Allocator, value: Value) !Spec.Xml {
    const object = try expectObject(value);
    return .{
        .name = try optionalString(allocator, object, "name"),
        .namespace = try optionalString(allocator, object, "namespace"),
        .prefix = try optionalString(allocator, object, "prefix"),
        .attribute = try optionalBool(object, "attribute") orelse false,
        .wrapped = try optionalBool(object, "wrapped") orelse false,
    };
}

fn parseExampleOrRef(allocator: Allocator, value: Value) !Spec.ExampleOrRef {
    const object = try expectObject(value);
    if (isReferenceObject(object)) {
        return .{ .reference = try parseReferenceObject(allocator, object) };
    }
    return .{ .example = try parseExample(allocator, value) };
}

fn parseExample(allocator: Allocator, value: Value) !Spec.Example {
    const object = try expectObject(value);
    return .{
        .summary = try optionalString(allocator, object, "summary"),
        .description = try optionalString(allocator, object, "description"),
        .value = if (object.get("value")) |item| try parseLiteral(allocator, item) else null,
        .external_value = try optionalString(allocator, object, "externalValue"),
    };
}

fn parseLinkOrRef(allocator: Allocator, value: Value) !Spec.LinkOrRef {
    const object = try expectObject(value);
    if (isReferenceObject(object)) {
        return .{ .reference = try parseReferenceObject(allocator, object) };
    }
    return .{ .link = try parseLink(allocator, value) };
}

fn parseLink(allocator: Allocator, value: Value) !Spec.Link {
    const object = try expectObject(value);
    return .{
        .operation_ref = try optionalString(allocator, object, "operationRef"),
        .operation_id = try optionalString(allocator, object, "operationId"),
        .parameters = try parseNamedMap(Spec.Literal, allocator, object.get("parameters"), parseLiteral),
        .request_body = if (object.get("requestBody")) |body| try parseLiteral(allocator, body) else null,
        .description = try optionalString(allocator, object, "description"),
        .server = if (object.get("server")) |server| try parseServer(allocator, server) else null,
    };
}

fn parseCallbackOrRef(allocator: Allocator, value: Value) !Spec.CallbackOrRef {
    const object = try expectObject(value);
    if (isReferenceObject(object)) {
        return .{ .reference = try parseReferenceObject(allocator, object) };
    }
    return .{ .callback = try parseCallback(allocator, value) };
}

fn parseCallback(allocator: Allocator, value: Value) !Spec.Callback {
    const object = try expectObject(value);
    _ = object;
    return .{
        .expressions = try parseNamedMap(Spec.PathItemOrRef, allocator, value, parsePathItemOrRef),
    };
}

fn parseSecuritySchemeOrRef(allocator: Allocator, value: Value) !Spec.SecuritySchemeOrRef {
    const object = try expectObject(value);
    if (isReferenceObject(object)) {
        return .{ .reference = try parseReferenceObject(allocator, object) };
    }
    return .{ .security_scheme = try parseSecurityScheme(allocator, value) };
}

fn parseSecurityScheme(allocator: Allocator, value: Value) !Spec.SecurityScheme {
    const object = try expectObject(value);
    return .{
        .kind = try requiredString(allocator, object, "type"),
        .description = try optionalString(allocator, object, "description"),
        .name = try optionalString(allocator, object, "name"),
        .location = try optionalString(allocator, object, "in"),
        .scheme = try optionalString(allocator, object, "scheme"),
        .bearer_format = try optionalString(allocator, object, "bearerFormat"),
        .flows = if (object.get("flows")) |flows| try parseOAuthFlows(allocator, flows) else null,
        .open_id_connect_url = try optionalString(allocator, object, "openIdConnectUrl"),
    };
}

fn parseOAuthFlows(allocator: Allocator, value: Value) !Spec.OAuthFlows {
    const object = try expectObject(value);
    return .{
        .implicit = if (object.get("implicit")) |flow| try parseOAuthFlow(allocator, flow) else null,
        .password = if (object.get("password")) |flow| try parseOAuthFlow(allocator, flow) else null,
        .client_credentials = if (object.get("clientCredentials")) |flow| try parseOAuthFlow(allocator, flow) else null,
        .authorization_code = if (object.get("authorizationCode")) |flow| try parseOAuthFlow(allocator, flow) else null,
    };
}

fn parseOAuthFlow(allocator: Allocator, value: Value) !Spec.OAuthFlow {
    const object = try expectObject(value);
    return .{
        .authorization_url = try optionalString(allocator, object, "authorizationUrl"),
        .token_url = try optionalString(allocator, object, "tokenUrl"),
        .refresh_url = try optionalString(allocator, object, "refreshUrl"),
        .scopes = try parseScopes(allocator, object.get("scopes")),
    };
}

fn parseScopes(allocator: Allocator, value: ?Value) ![]const Spec.Scope {
    if (value == null) return &.{};
    const object = try expectObject(value.?);
    var scopes = try allocator.alloc(Spec.Scope, object.count());
    for (object.keys(), object.values(), 0..) |name, scope_value, i| {
        scopes[i] = .{
            .name = try dupe(allocator, name),
            .description = try dupe(allocator, try expectString(scope_value)),
        };
    }
    return scopes;
}

fn parseSecurityRequirement(allocator: Allocator, value: Value) !Spec.SecurityRequirement {
    const object = try expectObject(value);
    var items = try allocator.alloc(Spec.SecurityRequirementItem, object.count());
    for (object.keys(), object.values(), 0..) |name, scopes_value, i| {
        items[i] = .{
            .name = try dupe(allocator, name),
            .scopes = try parseStringArray(allocator, scopes_value),
        };
    }
    return .{ .items = items };
}

fn parseReferenceObject(allocator: Allocator, object: ObjectMap) !Spec.Reference {
    return .{
        .ref_path = try requiredString(allocator, object, "$ref"),
        .summary = try optionalString(allocator, object, "summary"),
        .description = try optionalString(allocator, object, "description"),
    };
}

fn parseLiteral(allocator: Allocator, value: Value) !Spec.Literal {
    return switch (value) {
        .null => .null,
        .bool => |bool_value| .{ .bool = bool_value },
        .integer => |integer_value| .{ .integer = integer_value },
        .float => |float_value| .{ .float = float_value },
        .string => |string_value| .{ .string = try dupe(allocator, string_value) },
        .array => |array_value| blk: {
            var items = try allocator.alloc(Spec.Literal, array_value.items.len);
            for (array_value.items, 0..) |item, i| {
                items[i] = try parseLiteral(allocator, item);
            }
            break :blk .{ .array = items };
        },
        .object => |object_value| blk: {
            var items = try allocator.alloc(Spec.Named(Spec.Literal), object_value.count());
            for (object_value.keys(), object_value.values(), 0..) |name, item, i| {
                items[i] = .{
                    .name = try dupe(allocator, name),
                    .value = try parseLiteral(allocator, item),
                };
            }
            break :blk .{ .object = items };
        },
        else => error.InvalidLiteral,
    };
}

fn parseLiteralArray(allocator: Allocator, value: ?Value) ![]const Spec.Literal {
    if (value == null or value.? == .null) return &.{};
    const array = try expectArray(value.?);
    var items = try allocator.alloc(Spec.Literal, array.items.len);
    for (array.items, 0..) |item, i| {
        items[i] = try parseLiteral(allocator, item);
    }
    return items;
}

fn parseStringArray(allocator: Allocator, value: ?Value) ![]const []const u8 {
    if (value == null or value.? == .null) return &.{};
    const array = try expectArray(value.?);
    var items = try allocator.alloc([]const u8, array.items.len);
    for (array.items, 0..) |item, i| {
        items[i] = try dupe(allocator, try expectString(item));
    }
    return items;
}

fn parseStringItem(allocator: Allocator, value: Value) ![]const u8 {
    return try dupe(allocator, try expectString(value));
}

fn parseArray(
    comptime T: type,
    allocator: Allocator,
    value: ?Value,
    comptime parseItem: fn (Allocator, Value) anyerror!T,
) ![]const T {
    if (value == null or value.? == .null) return &.{};
    const array = try expectArray(value.?);
    var items = try allocator.alloc(T, array.items.len);
    for (array.items, 0..) |item, i| {
        items[i] = try parseItem(allocator, item);
    }
    return items;
}

fn parseNamedMap(
    comptime T: type,
    allocator: Allocator,
    value: ?Value,
    comptime parseItem: fn (Allocator, Value) anyerror!T,
) ![]const Spec.Named(T) {
    if (value == null or value.? == .null) return &.{};
    const object = try expectObject(value.?);
    var items = try allocator.alloc(Spec.Named(T), object.count());
    for (object.keys(), object.values(), 0..) |name, item_value, i| {
        items[i] = .{
            .name = try dupe(allocator, name),
            .value = try parseItem(allocator, item_value),
        };
    }
    return items;
}

fn parseParameterLocation(value: Value) !Spec.ParameterLocation {
    const location = try expectString(value);
    if (std.mem.eql(u8, location, "query")) return .query;
    if (std.mem.eql(u8, location, "header")) return .header;
    if (std.mem.eql(u8, location, "path")) return .path;
    if (std.mem.eql(u8, location, "cookie")) return .cookie;
    return error.InvalidParameterLocation;
}

fn allocOne(comptime T: type, allocator: Allocator, value: T) !*const T {
    const ptr = try allocator.create(T);
    ptr.* = value;
    return ptr;
}

fn expectObject(value: Value) !ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => error.ExpectedObject,
    };
}

fn expectArray(value: Value) !std.json.Array {
    return switch (value) {
        .array => |array| array,
        else => error.ExpectedArray,
    };
}

fn expectString(value: Value) ![]const u8 {
    return switch (value) {
        .string => |string_value| string_value,
        else => error.ExpectedString,
    };
}

fn optionalBool(object: ObjectMap, name: []const u8) !?bool {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .bool => |bool_value| bool_value,
        else => error.ExpectedBoolean,
    };
}

fn optionalNumber(object: ObjectMap, name: []const u8) !?f64 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .float => |float_value| float_value,
        .integer => |integer_value| @floatFromInt(integer_value),
        else => error.ExpectedNumber,
    };
}

fn optionalU64(object: ObjectMap, name: []const u8) !?u64 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .integer => |integer_value| {
            if (integer_value < 0) return error.ExpectedNumber;
            return @intCast(integer_value);
        },
        else => error.ExpectedNumber,
    };
}

fn optionalString(allocator: Allocator, object: ObjectMap, name: []const u8) !?[]const u8 {
    const value = object.get(name) orelse return null;
    return try dupe(allocator, try expectString(value));
}

fn requiredString(allocator: Allocator, object: ObjectMap, name: []const u8) ![]const u8 {
    const value = object.get(name) orelse return error.MissingField;
    return try dupe(allocator, try expectString(value));
}

fn dupe(allocator: Allocator, value: []const u8) ![]const u8 {
    return try allocator.dupe(u8, value);
}

fn isReferenceObject(object: ObjectMap) bool {
    return object.get("$ref") != null;
}

const ComptimeParser = struct {
    source: []const u8,
    index: usize = 0,

    const Self = @This();

    fn parseSpec(self: *Self) !Spec {
        try self.expectChar('{');
        self.skipWhitespace();

        var spec: Spec = .{};
        if (self.consumeChar('}')) return spec;

        while (true) {
            const field_name = try self.parseString();
            try self.expectChar(':');

            if (std.mem.eql(u8, field_name, "openapi")) {
                spec.openapi = try self.parseString();
            } else if (std.mem.eql(u8, field_name, "info")) {
                spec.info = try self.parseInfo();
            } else if (std.mem.eql(u8, field_name, "servers")) {
                spec.servers = try self.parseArray(Spec.Server, Self.parseServerValue);
            } else if (std.mem.eql(u8, field_name, "paths")) {
                spec.paths = try self.parseNamedMap(Spec.PathItemOrRef, Self.parsePathItemOrRefValue);
            } else if (std.mem.eql(u8, field_name, "components")) {
                spec.components = try self.parseComponents();
            } else {
                try self.skipValue();
            }

            self.skipWhitespace();
            if (self.consumeChar('}')) break;
            try self.expectChar(',');
        }

        return spec;
    }

    fn parseInfo(self: *Self) !Spec.Info {
        try self.expectChar('{');
        self.skipWhitespace();

        var info: Spec.Info = .{};
        if (self.consumeChar('}')) return info;

        while (true) {
            const field_name = try self.parseString();
            try self.expectChar(':');

            if (std.mem.eql(u8, field_name, "title")) {
                info.title = try self.parseString();
            } else if (std.mem.eql(u8, field_name, "version")) {
                info.version = try self.parseString();
            } else {
                try self.skipValue();
            }

            self.skipWhitespace();
            if (self.consumeChar('}')) break;
            try self.expectChar(',');
        }

        return info;
    }

    fn parseComponents(self: *Self) !Spec.Components {
        try self.expectChar('{');
        self.skipWhitespace();

        var components: Spec.Components = .{};
        if (self.consumeChar('}')) return components;

        while (true) {
            const field_name = try self.parseString();
            try self.expectChar(':');

            if (std.mem.eql(u8, field_name, "schemas")) {
                components.schemas = try self.parseNamedMap(Spec.SchemaOrRef, Self.parseSchemaOrRefValue);
            } else if (std.mem.eql(u8, field_name, "parameters")) {
                components.parameters = try self.parseNamedMap(Spec.ParameterOrRef, Self.parseParameterOrRefValue);
            } else if (std.mem.eql(u8, field_name, "requestBodies")) {
                components.request_bodies = try self.parseNamedMap(Spec.RequestBodyOrRef, Self.parseRequestBodyOrRefValue);
            } else if (std.mem.eql(u8, field_name, "responses")) {
                components.responses = try self.parseNamedMap(Spec.ResponseOrRef, Self.parseResponseOrRefValue);
            } else {
                try self.skipValue();
            }

            self.skipWhitespace();
            if (self.consumeChar('}')) break;
            try self.expectChar(',');
        }

        return components;
    }

    fn parseServerValue(self: *Self) !Spec.Server {
        try self.expectChar('{');
        self.skipWhitespace();

        var server: Spec.Server = .{};
        if (self.consumeChar('}')) return server;

        while (true) {
            const field_name = try self.parseString();
            try self.expectChar(':');

            if (std.mem.eql(u8, field_name, "url")) {
                server.url = try self.parseString();
            } else if (std.mem.eql(u8, field_name, "description")) {
                try self.skipValue();
            } else {
                try self.skipValue();
            }

            self.skipWhitespace();
            if (self.consumeChar('}')) break;
            try self.expectChar(',');
        }

        return server;
    }

    fn parsePathItemOrRefValue(self: *Self) !Spec.PathItemOrRef {
        try self.expectChar('{');
        self.skipWhitespace();

        var path_item: Spec.PathItem = .{};
        var reference: Spec.Reference = .{};
        var saw_ref = false;

        if (self.consumeChar('}')) return .{ .path_item = path_item };

        while (true) {
            const field_name = try self.parseString();
            try self.expectChar(':');

            if (std.mem.eql(u8, field_name, "$ref")) {
                reference.ref_path = try self.parseString();
                saw_ref = true;
            } else if (std.mem.eql(u8, field_name, "summary")) {
                try self.skipValue();
            } else if (std.mem.eql(u8, field_name, "description")) {
                try self.skipValue();
            } else if (std.mem.eql(u8, field_name, "parameters")) {
                path_item.parameters = try self.parseArray(Spec.ParameterOrRef, Self.parseParameterOrRefValue);
            } else if (std.mem.eql(u8, field_name, "get")) {
                path_item.get = try self.parseOperationValue();
            } else if (std.mem.eql(u8, field_name, "put")) {
                path_item.put = try self.parseOperationValue();
            } else if (std.mem.eql(u8, field_name, "post")) {
                path_item.post = try self.parseOperationValue();
            } else if (std.mem.eql(u8, field_name, "delete")) {
                path_item.delete = try self.parseOperationValue();
            } else if (std.mem.eql(u8, field_name, "options")) {
                path_item.options = try self.parseOperationValue();
            } else if (std.mem.eql(u8, field_name, "head")) {
                path_item.head = try self.parseOperationValue();
            } else if (std.mem.eql(u8, field_name, "patch")) {
                path_item.patch = try self.parseOperationValue();
            } else if (std.mem.eql(u8, field_name, "trace")) {
                path_item.trace = try self.parseOperationValue();
            } else {
                try self.skipValue();
            }

            self.skipWhitespace();
            if (self.consumeChar('}')) break;
            try self.expectChar(',');
        }

        if (saw_ref) return .{ .reference = reference };
        return .{ .path_item = path_item };
    }

    fn parseOperationValue(self: *Self) !Spec.Operation {
        try self.expectChar('{');
        self.skipWhitespace();

        var operation: Spec.Operation = .{};
        if (self.consumeChar('}')) return operation;

        while (true) {
            const field_name = try self.parseString();
            try self.expectChar(':');

            if (std.mem.eql(u8, field_name, "operationId")) {
                operation.operation_id = try self.parseString();
            } else if (std.mem.eql(u8, field_name, "summary")) {
                try self.skipValue();
            } else if (std.mem.eql(u8, field_name, "description")) {
                try self.skipValue();
            } else if (std.mem.eql(u8, field_name, "parameters")) {
                operation.parameters = try self.parseArray(Spec.ParameterOrRef, Self.parseParameterOrRefValue);
            } else if (std.mem.eql(u8, field_name, "requestBody")) {
                operation.request_body = try self.parseRequestBodyOrRefValue();
            } else if (std.mem.eql(u8, field_name, "responses")) {
                operation.responses = try self.parseNamedMap(Spec.ResponseOrRef, Self.parseResponseOrRefValue);
            } else {
                try self.skipValue();
            }

            self.skipWhitespace();
            if (self.consumeChar('}')) break;
            try self.expectChar(',');
        }

        return operation;
    }

    fn parseParameterOrRefValue(self: *Self) !Spec.ParameterOrRef {
        try self.expectChar('{');
        self.skipWhitespace();

        var parameter: Spec.Parameter = .{};
        var reference: Spec.Reference = .{};
        var saw_ref = false;

        if (self.consumeChar('}')) return .{ .parameter = parameter };

        while (true) {
            const field_name = try self.parseString();
            try self.expectChar(':');

            if (std.mem.eql(u8, field_name, "$ref")) {
                reference.ref_path = try self.parseString();
                saw_ref = true;
            } else if (std.mem.eql(u8, field_name, "name")) {
                parameter.name = try self.parseString();
            } else if (std.mem.eql(u8, field_name, "in")) {
                parameter.location = try self.parseParameterLocationValue();
            } else if (std.mem.eql(u8, field_name, "required")) {
                parameter.required = try self.parseBool();
            } else if (std.mem.eql(u8, field_name, "description")) {
                try self.skipValue();
            } else if (std.mem.eql(u8, field_name, "schema")) {
                const schema = try self.parseSchemaOrRefValue();
                parameter.schema = &schema;
            } else {
                try self.skipValue();
            }

            self.skipWhitespace();
            if (self.consumeChar('}')) break;
            try self.expectChar(',');
        }

        if (saw_ref) return .{ .reference = reference };
        return .{ .parameter = parameter };
    }

    fn parseRequestBodyOrRefValue(self: *Self) !Spec.RequestBodyOrRef {
        try self.expectChar('{');
        self.skipWhitespace();

        var request_body: Spec.RequestBody = .{};
        var reference: Spec.Reference = .{};
        var saw_ref = false;

        if (self.consumeChar('}')) return .{ .request_body = request_body };

        while (true) {
            const field_name = try self.parseString();
            try self.expectChar(':');

            if (std.mem.eql(u8, field_name, "$ref")) {
                reference.ref_path = try self.parseString();
                saw_ref = true;
            } else if (std.mem.eql(u8, field_name, "description")) {
                try self.skipValue();
            } else if (std.mem.eql(u8, field_name, "required")) {
                request_body.required = try self.parseBool();
            } else if (std.mem.eql(u8, field_name, "content")) {
                request_body.content = try self.parseNamedMap(Spec.MediaType, Self.parseMediaTypeValue);
            } else {
                try self.skipValue();
            }

            self.skipWhitespace();
            if (self.consumeChar('}')) break;
            try self.expectChar(',');
        }

        if (saw_ref) return .{ .reference = reference };
        return .{ .request_body = request_body };
    }

    fn parseResponseOrRefValue(self: *Self) !Spec.ResponseOrRef {
        try self.expectChar('{');
        self.skipWhitespace();

        var response: Spec.Response = .{};
        var reference: Spec.Reference = .{};
        var saw_ref = false;

        if (self.consumeChar('}')) return .{ .response = response };

        while (true) {
            const field_name = try self.parseString();
            try self.expectChar(':');

            if (std.mem.eql(u8, field_name, "$ref")) {
                reference.ref_path = try self.parseString();
                saw_ref = true;
            } else if (std.mem.eql(u8, field_name, "description")) {
                try self.skipValue();
            } else if (std.mem.eql(u8, field_name, "content")) {
                response.content = try self.parseNamedMap(Spec.MediaType, Self.parseMediaTypeValue);
            } else {
                try self.skipValue();
            }

            self.skipWhitespace();
            if (self.consumeChar('}')) break;
            try self.expectChar(',');
        }

        if (saw_ref) return .{ .reference = reference };
        return .{ .response = response };
    }

    fn parseMediaTypeValue(self: *Self) !Spec.MediaType {
        try self.expectChar('{');
        self.skipWhitespace();

        var media_type: Spec.MediaType = .{};
        if (self.consumeChar('}')) return media_type;

        while (true) {
            const field_name = try self.parseString();
            try self.expectChar(':');

            if (std.mem.eql(u8, field_name, "schema")) {
                const schema = try self.parseSchemaOrRefValue();
                media_type.schema = &schema;
            } else {
                try self.skipValue();
            }

            self.skipWhitespace();
            if (self.consumeChar('}')) break;
            try self.expectChar(',');
        }

        return media_type;
    }

    fn parseParameterLocationValue(self: *Self) !Spec.ParameterLocation {
        const location = try self.parseString();
        if (std.mem.eql(u8, location, "query")) return .query;
        if (std.mem.eql(u8, location, "header")) return .header;
        if (std.mem.eql(u8, location, "path")) return .path;
        if (std.mem.eql(u8, location, "cookie")) return .cookie;
        return error.InvalidParameterLocation;
    }

    fn parseSchemaOrRefValue(self: *Self) !Spec.SchemaOrRef {
        try self.expectChar('{');
        self.skipWhitespace();

        var schema: Spec.Schema = .{};
        var reference: Spec.Reference = .{};
        var saw_ref = false;

        if (self.consumeChar('}')) return .{ .schema = schema };

        while (true) {
            const field_name = try self.parseString();
            try self.expectChar(':');

            if (std.mem.eql(u8, field_name, "$ref")) {
                reference.ref_path = try self.parseString();
                saw_ref = true;
            } else if (std.mem.eql(u8, field_name, "type")) {
                schema.schema_type = try self.parseString();
            } else if (std.mem.eql(u8, field_name, "format")) {
                schema.format = try self.parseString();
            } else if (std.mem.eql(u8, field_name, "required")) {
                schema.required = try self.parseStringArray();
            } else if (std.mem.eql(u8, field_name, "properties")) {
                schema.properties = try self.parseNamedMap(Spec.SchemaOrRef, Self.parseSchemaOrRefValue);
            } else if (std.mem.eql(u8, field_name, "items")) {
                const item = try self.parseSchemaOrRefValue();
                schema.items = &item;
            } else if (std.mem.eql(u8, field_name, "nullable")) {
                schema.nullable = try self.parseBool();
            } else if (std.mem.eql(u8, field_name, "allOf")) {
                schema.all_of = try self.parseArray(Spec.SchemaOrRef, Self.parseSchemaOrRefValue);
            } else if (std.mem.eql(u8, field_name, "oneOf")) {
                schema.one_of = try self.parseArray(Spec.SchemaOrRef, Self.parseSchemaOrRefValue);
            } else if (std.mem.eql(u8, field_name, "anyOf")) {
                schema.any_of = try self.parseArray(Spec.SchemaOrRef, Self.parseSchemaOrRefValue);
            } else if (std.mem.eql(u8, field_name, "additionalProperties")) {
                schema.additional_properties = try self.parseAdditionalProperties();
            } else if (std.mem.eql(u8, field_name, "discriminator")) {
                schema.discriminator = try self.parseDiscriminator();
            } else {
                try self.skipValue();
            }

            self.skipWhitespace();
            if (self.consumeChar('}')) break;
            try self.expectChar(',');
        }

        if (saw_ref) return .{ .reference = reference };
        return .{ .schema = schema };
    }

    fn parseAdditionalProperties(self: *Self) !Spec.AdditionalProperties {
        self.skipWhitespace();
        return switch (self.peekChar() orelse return error.UnexpectedEndOfInput) {
            't', 'f' => .{ .boolean = try self.parseBool() },
            '{' => blk: {
                const schema = try self.parseSchemaOrRefValue();
                break :blk .{ .schema = &schema };
            },
            else => error.ExpectedObject,
        };
    }

    fn parseDiscriminator(self: *Self) !Spec.Discriminator {
        try self.expectChar('{');
        self.skipWhitespace();

        var discriminator: Spec.Discriminator = .{};
        if (self.consumeChar('}')) return discriminator;

        while (true) {
            const field_name = try self.parseString();
            try self.expectChar(':');

            if (std.mem.eql(u8, field_name, "propertyName")) {
                discriminator.property_name = try self.parseString();
            } else if (std.mem.eql(u8, field_name, "mapping")) {
                discriminator.mapping = try self.parseNamedMap([]const u8, Self.parseStringValue);
            } else {
                try self.skipValue();
            }

            self.skipWhitespace();
            if (self.consumeChar('}')) break;
            try self.expectChar(',');
        }

        return discriminator;
    }

    fn parseStringArray(self: *Self) ![]const []const u8 {
        return try self.parseArray([]const u8, parseStringValue);
    }

    fn parseStringValue(self: *Self) ![]const u8 {
        return try self.parseString();
    }

    fn parseArray(
        self: *Self,
        comptime T: type,
        comptime parseItem: fn (*Self) anyerror!T,
    ) ![]const T {
        const count = try self.peekArrayItemCount();
        var items: [count]T = undefined;

        try self.expectChar('[');
        self.skipWhitespace();
        if (self.consumeChar(']')) return items[0..];

        var i: usize = 0;
        while (true) : (i += 1) {
            items[i] = try parseItem(self);
            self.skipWhitespace();
            if (self.consumeChar(']')) break;
            try self.expectChar(',');
        }
        return items[0..];
    }

    fn parseNamedMap(
        self: *Self,
        comptime T: type,
        comptime parseItem: fn (*Self) anyerror!T,
    ) ![]const Spec.Named(T) {
        const count = try self.peekObjectEntryCount();
        var items: [count]Spec.Named(T) = undefined;

        try self.expectChar('{');
        self.skipWhitespace();
        if (self.consumeChar('}')) return items[0..];

        var i: usize = 0;
        while (true) : (i += 1) {
            items[i] = .{
                .name = try self.parseString(),
                .value = blk: {
                    try self.expectChar(':');
                    break :blk try parseItem(self);
                },
            };
            self.skipWhitespace();
            if (self.consumeChar('}')) break;
            try self.expectChar(',');
        }
        return items[0..];
    }

    fn peekObjectEntryCount(self: *const Self) !usize {
        var copy = self.*;
        try copy.expectChar('{');
        var count: usize = 0;

        copy.skipWhitespace();
        if (copy.consumeChar('}')) return 0;

        while (true) {
            _ = try copy.parseString();
            try copy.expectChar(':');
            try copy.skipValue();
            count += 1;

            copy.skipWhitespace();
            if (copy.consumeChar('}')) break;
            try copy.expectChar(',');
        }

        return count;
    }

    fn peekArrayItemCount(self: *const Self) !usize {
        var copy = self.*;
        try copy.expectChar('[');
        var count: usize = 0;

        copy.skipWhitespace();
        if (copy.consumeChar(']')) return 0;

        while (true) {
            try copy.skipValue();
            count += 1;

            copy.skipWhitespace();
            if (copy.consumeChar(']')) break;
            try copy.expectChar(',');
        }

        return count;
    }

    fn skipValue(self: *Self) !void {
        self.skipWhitespace();
        const ch = self.peekChar() orelse return error.UnexpectedEndOfInput;

        switch (ch) {
            '{' => {
                try self.expectChar('{');
                self.skipWhitespace();
                if (self.consumeChar('}')) return;

                while (true) {
                    _ = try self.parseString();
                    try self.expectChar(':');
                    try self.skipValue();
                    self.skipWhitespace();
                    if (self.consumeChar('}')) break;
                    try self.expectChar(',');
                }
            },
            '[' => {
                try self.expectChar('[');
                self.skipWhitespace();
                if (self.consumeChar(']')) return;

                while (true) {
                    try self.skipValue();
                    self.skipWhitespace();
                    if (self.consumeChar(']')) break;
                    try self.expectChar(',');
                }
            },
            '"' => try self.skipString(),
            't', 'f' => _ = try self.parseBool(),
            'n' => try self.parseNull(),
            '-', '0'...'9' => try self.skipNumber(),
            else => return error.UnexpectedToken,
        }
    }

    fn parseString(self: *Self) ![]const u8 {
        try self.expectChar('"');
        const start = self.index;
        var escaped = false;

        while (true) {
            const ch = self.peekChar() orelse return error.UnexpectedEndOfInput;
            self.index += 1;

            if (escaped) {
                escaped = false;
                continue;
            }

            if (ch == '\\') {
                escaped = true;
                continue;
            }

            if (ch == '"') {
                const end = self.index - 1;
                const slice = self.source[start..end];
                if (std.mem.indexOfScalar(u8, slice, '\\') == null) return slice;
                return decodeEscapedString(slice);
            }
        }
    }

    fn decodeEscapedString(comptime slice: []const u8) ![]const u8 {
        comptime var escape_count: usize = 0;
        comptime var index: usize = 0;
        while (index < slice.len) : (index += 1) {
            if (slice[index] == '\\') {
                if (index + 1 >= slice.len) return error.UnsupportedEscapedString;
                escape_count += 1;
                if (slice[index + 1] == 'u') return error.UnsupportedEscapedString;
                index += 1;
            }
        }

        comptime var buffer: [slice.len - escape_count]u8 = undefined;
        comptime var out_index: usize = 0;
        index = 0;
        while (index < slice.len) : (index += 1) {
            if (slice[index] != '\\') {
                buffer[out_index] = slice[index];
                out_index += 1;
                continue;
            }

            index += 1;
            if (index >= slice.len) return error.UnsupportedEscapedString;
            buffer[out_index] = switch (slice[index]) {
                '"', '\\', '/' => slice[index],
                'b' => 0x08,
                'f' => 0x0c,
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                else => return error.UnsupportedEscapedString,
            };
            out_index += 1;
        }

        return std.fmt.comptimePrint("{s}", .{buffer[0..out_index]});
    }

    fn skipString(self: *Self) !void {
        try self.expectChar('"');
        var escaped = false;

        while (true) {
            const ch = self.peekChar() orelse return error.UnexpectedEndOfInput;
            self.index += 1;

            if (escaped) {
                escaped = false;
                continue;
            }

            if (ch == '\\') {
                escaped = true;
                continue;
            }

            if (ch == '"') return;
        }
    }

    fn parseBool(self: *Self) !bool {
        if (self.consumeKeyword("true")) return true;
        if (self.consumeKeyword("false")) return false;
        return error.ExpectedBoolean;
    }

    fn parseNull(self: *Self) !void {
        if (!self.consumeKeyword("null")) return error.ExpectedNull;
    }

    fn skipNumber(self: *Self) !void {
        self.skipWhitespace();
        if (self.peekChar() == null) return error.UnexpectedEndOfInput;

        if (self.peekChar().? == '-') self.index += 1;
        try self.skipDigits();

        if (self.peekChar()) |ch| {
            if (ch == '.') {
                self.index += 1;
                try self.skipDigits();
            }
        }

        if (self.peekChar()) |ch| {
            if (ch == 'e' or ch == 'E') {
                self.index += 1;
                if (self.peekChar()) |sign| {
                    if (sign == '+' or sign == '-') self.index += 1;
                }
                try self.skipDigits();
            }
        }
    }

    fn skipDigits(self: *Self) !void {
        var saw_digit = false;
        while (self.peekChar()) |ch| {
            if (!std.ascii.isDigit(ch)) break;
            self.index += 1;
            saw_digit = true;
        }
        if (!saw_digit) return error.ExpectedNumber;
    }

    fn consumeKeyword(self: *Self, comptime keyword: []const u8) bool {
        self.skipWhitespace();
        if (!std.mem.startsWith(u8, self.source[self.index..], keyword)) return false;
        self.index += keyword.len;
        return true;
    }

    fn expectChar(self: *Self, expected: u8) !void {
        if (expected == 0) return;
        self.skipWhitespace();
        const ch = self.peekChar() orelse return error.UnexpectedEndOfInput;
        if (ch != expected) return error.UnexpectedToken;
        self.index += 1;
    }

    fn consumeChar(self: *Self, expected: u8) bool {
        self.skipWhitespace();
        const ch = self.peekChar() orelse return false;
        if (ch != expected) return false;
        self.index += 1;
        return true;
    }

    fn peekChar(self: *const Self) ?u8 {
        if (self.index >= self.source.len) return null;
        return self.source[self.index];
    }

    fn skipWhitespace(self: *Self) void {
        while (self.index < self.source.len) {
            switch (self.source[self.index]) {
                ' ', '\n', '\r', '\t' => self.index += 1,
                else => return,
            }
        }
    }
};
