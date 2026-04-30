const std = @import("std");
const Self = @This();

openapi: []const u8 = "",
info: Info = .{},
servers: []const Server = &.{},
paths: []const Named(PathItemOrRef) = &.{},
components: ?Components = null,
security: []const SecurityRequirement = &.{},
tags: []const Tag = &.{},
external_docs: ?ExternalDocumentation = null,

pub const Info = struct {
    title: []const u8 = "",
    summary: ?[]const u8 = null,
    description: ?[]const u8 = null,
    terms_of_service: ?[]const u8 = null,
    contact: ?Contact = null,
    license: ?License = null,
    version: []const u8 = "",
};

pub const Contact = struct {
    name: ?[]const u8 = null,
    url: ?[]const u8 = null,
    email: ?[]const u8 = null,
};

pub const License = struct {
    name: []const u8 = "",
    identifier: ?[]const u8 = null,
    url: ?[]const u8 = null,
};

pub const ExternalDocumentation = struct {
    description: ?[]const u8 = null,
    url: []const u8 = "",
};

pub const Server = struct {
    url: []const u8 = "",
    description: ?[]const u8 = null,
    variables: []const Named(ServerVariable) = &.{},
};

pub const ServerVariable = struct {
    enum_values: []const []const u8 = &.{},
    default_value: []const u8 = "",
    description: ?[]const u8 = null,
};

pub const Tag = struct {
    name: []const u8 = "",
    description: ?[]const u8 = null,
    external_docs: ?ExternalDocumentation = null,
};

pub const Components = struct {
    schemas: []const Named(SchemaOrRef) = &.{},
    responses: []const Named(ResponseOrRef) = &.{},
    parameters: []const Named(ParameterOrRef) = &.{},
    examples: []const Named(ExampleOrRef) = &.{},
    request_bodies: []const Named(RequestBodyOrRef) = &.{},
    headers: []const Named(HeaderOrRef) = &.{},
    security_schemes: []const Named(SecuritySchemeOrRef) = &.{},
    links: []const Named(LinkOrRef) = &.{},
    callbacks: []const Named(CallbackOrRef) = &.{},
};

pub const Reference = struct {
    ref_path: []const u8 = "",
    summary: ?[]const u8 = null,
    description: ?[]const u8 = null,
};

pub const PathItemOrRef = union(enum) {
    path_item: PathItem,
    reference: Reference,
};

pub const PathItem = struct {
    summary: ?[]const u8 = null,
    description: ?[]const u8 = null,
    get: ?Operation = null,
    put: ?Operation = null,
    post: ?Operation = null,
    delete: ?Operation = null,
    options: ?Operation = null,
    head: ?Operation = null,
    patch: ?Operation = null,
    trace: ?Operation = null,
    servers: []const Server = &.{},
    parameters: []const ParameterOrRef = &.{},
};

pub const Operation = struct {
    tags: []const []const u8 = &.{},
    summary: ?[]const u8 = null,
    description: ?[]const u8 = null,
    external_docs: ?ExternalDocumentation = null,
    operation_id: ?[]const u8 = null,
    parameters: []const ParameterOrRef = &.{},
    request_body: ?RequestBodyOrRef = null,
    responses: []const Named(ResponseOrRef) = &.{},
    callbacks: []const Named(CallbackOrRef) = &.{},
    deprecated: bool = false,
    security: []const SecurityRequirement = &.{},
    servers: []const Server = &.{},
};

pub const ParameterOrRef = union(enum) {
    parameter: Parameter,
    reference: Reference,
};

pub const ParameterLocation = enum {
    query,
    header,
    path,
    cookie,
};

pub const Parameter = struct {
    name: []const u8 = "",
    location: ParameterLocation = .query,
    description: ?[]const u8 = null,
    required: bool = false,
    deprecated: bool = false,
    allow_empty_value: bool = false,
    style: ?[]const u8 = null,
    explode: ?bool = null,
    allow_reserved: bool = false,
    schema: ?*const SchemaOrRef = null,
    example: ?Literal = null,
    content: []const Named(MediaType) = &.{},
};

pub const RequestBodyOrRef = union(enum) {
    request_body: RequestBody,
    reference: Reference,
};

pub const RequestBody = struct {
    description: ?[]const u8 = null,
    content: []const Named(MediaType) = &.{},
    required: bool = false,
};

pub const ResponseOrRef = union(enum) {
    response: Response,
    reference: Reference,
};

pub const Response = struct {
    description: []const u8 = "",
    headers: []const Named(HeaderOrRef) = &.{},
    content: []const Named(MediaType) = &.{},
    links: []const Named(LinkOrRef) = &.{},
};

pub const HeaderOrRef = union(enum) {
    header: Header,
    reference: Reference,
};

pub const Header = struct {
    description: ?[]const u8 = null,
    required: bool = false,
    deprecated: bool = false,
    allow_empty_value: bool = false,
    style: ?[]const u8 = null,
    explode: ?bool = null,
    allow_reserved: bool = false,
    schema: ?*const SchemaOrRef = null,
    example: ?Literal = null,
    content: []const Named(MediaType) = &.{},
};

pub const MediaType = struct {
    schema: ?*const SchemaOrRef = null,
    example: ?Literal = null,
    examples: []const Named(ExampleOrRef) = &.{},
    encoding: []const Named(Encoding) = &.{},
};

pub const Encoding = struct {
    content_type: ?[]const u8 = null,
    headers: []const Named(HeaderOrRef) = &.{},
    style: ?[]const u8 = null,
    explode: ?bool = null,
    allow_reserved: bool = false,
};

pub const SchemaOrRef = union(enum) {
    schema: Schema,
    reference: Reference,
};

pub const AdditionalProperties = union(enum) {
    boolean: bool,
    schema: *const SchemaOrRef,
};

pub const Schema = struct {
    title: ?[]const u8 = null,
    multiple_of: ?f64 = null,
    maximum: ?f64 = null,
    exclusive_maximum: ?bool = null,
    minimum: ?f64 = null,
    exclusive_minimum: ?bool = null,
    max_length: ?u64 = null,
    min_length: ?u64 = null,
    pattern: ?[]const u8 = null,
    max_items: ?u64 = null,
    min_items: ?u64 = null,
    unique_items: bool = false,
    max_properties: ?u64 = null,
    min_properties: ?u64 = null,
    required: []const []const u8 = &.{},
    enum_values: []const Literal = &.{},
    schema_type: ?[]const u8 = null,
    all_of: []const SchemaOrRef = &.{},
    one_of: []const SchemaOrRef = &.{},
    any_of: []const SchemaOrRef = &.{},
    items: ?*const SchemaOrRef = null,
    properties: []const Named(SchemaOrRef) = &.{},
    additional_properties: ?AdditionalProperties = null,
    discriminator: ?Discriminator = null,
    description: ?[]const u8 = null,
    format: ?[]const u8 = null,
    default: ?Literal = null,
    nullable: bool = false,
    read_only: bool = false,
    write_only: bool = false,
    example: ?Literal = null,
    deprecated: bool = false,
    xml: ?Xml = null,
};

pub const Discriminator = struct {
    property_name: []const u8 = "",
    mapping: []const Named([]const u8) = &.{},
};

pub const Xml = struct {
    name: ?[]const u8 = null,
    namespace: ?[]const u8 = null,
    prefix: ?[]const u8 = null,
    attribute: bool = false,
    wrapped: bool = false,
};

pub const ExampleOrRef = union(enum) {
    example: Example,
    reference: Reference,
};

pub const Example = struct {
    summary: ?[]const u8 = null,
    description: ?[]const u8 = null,
    value: ?Literal = null,
    external_value: ?[]const u8 = null,
};

pub const LinkOrRef = union(enum) {
    link: Link,
    reference: Reference,
};

pub const Link = struct {
    operation_ref: ?[]const u8 = null,
    operation_id: ?[]const u8 = null,
    parameters: []const Named(Literal) = &.{},
    request_body: ?Literal = null,
    description: ?[]const u8 = null,
    server: ?Server = null,
};

pub const CallbackOrRef = union(enum) {
    callback: Callback,
    reference: Reference,
};

pub const Callback = struct {
    expressions: []const Named(PathItemOrRef) = &.{},
};

pub const SecuritySchemeOrRef = union(enum) {
    security_scheme: SecurityScheme,
    reference: Reference,
};

pub const SecurityScheme = struct {
    kind: []const u8 = "",
    description: ?[]const u8 = null,
    name: ?[]const u8 = null,
    location: ?[]const u8 = null,
    scheme: ?[]const u8 = null,
    bearer_format: ?[]const u8 = null,
    flows: ?OAuthFlows = null,
    open_id_connect_url: ?[]const u8 = null,
};

pub const OAuthFlows = struct {
    implicit: ?OAuthFlow = null,
    password: ?OAuthFlow = null,
    client_credentials: ?OAuthFlow = null,
    authorization_code: ?OAuthFlow = null,
};

pub const OAuthFlow = struct {
    authorization_url: ?[]const u8 = null,
    token_url: ?[]const u8 = null,
    refresh_url: ?[]const u8 = null,
    scopes: []const Scope = &.{},
};

pub const Scope = struct {
    name: []const u8 = "",
    description: []const u8 = "",
};

pub const SecurityRequirement = struct {
    items: []const SecurityRequirementItem = &.{},
};

pub const SecurityRequirementItem = struct {
    name: []const u8 = "",
    scopes: []const []const u8 = &.{},
};

pub const Literal = union(enum) {
    null,
    bool: bool,
    integer: i64,
    float: f64,
    string: []const u8,
    array: []const Literal,
    object: []const Named(Literal),
};

pub fn Named(comptime T: type) type {
    return struct {
        name: []const u8,
        value: T,
    };
}

pub fn shallow(comptime raw_document: []const u8, comptime title: []const u8, comptime version: []const u8, comptime openapi_version: []const u8) Self {
    _ = raw_document;
    return .{
        .openapi = openapi_version,
        .info = .{
            .title = title,
            .version = version,
        },
    };
}

pub fn findPath(self: Self, name: []const u8) ?PathItemOrRef {
    return findNamed(PathItemOrRef, self.paths, name);
}

pub fn findSchema(self: Self, name: []const u8) ?SchemaOrRef {
    const components = self.components orelse return null;
    return findNamed(SchemaOrRef, components.schemas, name);
}

pub fn findNamed(comptime T: type, items: []const Named(T), name: []const u8) ?T {
    for (items) |item| {
        if (std.mem.eql(u8, item.name, name)) return item.value;
    }
    return null;
}
