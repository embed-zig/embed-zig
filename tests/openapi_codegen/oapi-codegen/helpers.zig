const std = @import("std");
const openapi = @import("openapi");

const Spec = openapi.Spec;
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;

pub fn assertDetailedFixture(comptime fixture: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const spec = try openapi.json.parseAlloc(arena.allocator(), fixture);
    const emitted = try openapi.json.stringifyAlloc(arena.allocator(), spec);
    const reparsed = try openapi.json.parseAlloc(arena.allocator(), emitted);
    const emitted_again = try openapi.json.stringifyAlloc(arena.allocator(), reparsed);

    try std.testing.expectEqualStrings(emitted, emitted_again);

    const parsed_json = try std.json.parseFromSlice(Value, arena.allocator(), fixture, .{
        .allocate = .alloc_if_needed,
    });
    try compareSpec(try expectObject(parsed_json.value), spec);
}

fn compareSpec(raw: ObjectMap, spec: Spec) !void {
    try expectPresentOrDefaultString(raw, "openapi", spec.openapi);
    try compareInfo(try optionalObject(raw.get("info")), spec.info);
    try compareServers(try optionalArray(raw.get("servers")), spec.servers);
    try compareTags(try optionalArray(raw.get("tags")), spec.tags);
    try comparePaths(try optionalObject(raw.get("paths")), spec);
    try compareComponents(try optionalObject(raw.get("components")), spec.components);
    try compareSecurityRequirements(try optionalArray(raw.get("security")), spec.security);
    try compareExternalDocumentation(try optionalObject(raw.get("externalDocs")), spec.external_docs);
}

fn compareInfo(raw: ?ObjectMap, info: Spec.Info) !void {
    if (raw) |object| {
        try expectPresentOrDefaultString(object, "title", info.title);
        try expectPresentOrDefaultString(object, "version", info.version);
        try expectOptionalString(object, "summary", info.summary);
        try expectOptionalString(object, "description", info.description);
        try expectOptionalString(object, "termsOfService", info.terms_of_service);
        try compareContact(try optionalObject(object.get("contact")), info.contact);
        try compareLicense(try optionalObject(object.get("license")), info.license);
    } else {
        try std.testing.expectEqualStrings("", info.title);
        try std.testing.expectEqualStrings("", info.version);
        try std.testing.expect(info.summary == null);
        try std.testing.expect(info.description == null);
        try std.testing.expect(info.terms_of_service == null);
        try std.testing.expect(info.contact == null);
        try std.testing.expect(info.license == null);
    }
}

fn compareContact(raw: ?ObjectMap, contact: ?Spec.Contact) !void {
    if (raw) |object| {
        const parsed = contact orelse return error.MissingField;
        try expectOptionalString(object, "name", parsed.name);
        try expectOptionalString(object, "url", parsed.url);
        try expectOptionalString(object, "email", parsed.email);
    } else {
        try std.testing.expect(contact == null);
    }
}

fn compareLicense(raw: ?ObjectMap, license: ?Spec.License) !void {
    if (raw) |object| {
        const parsed = license orelse return error.MissingField;
        try expectPresentOrDefaultString(object, "name", parsed.name);
        try expectOptionalString(object, "identifier", parsed.identifier);
        try expectOptionalString(object, "url", parsed.url);
    } else {
        try std.testing.expect(license == null);
    }
}

fn compareExternalDocumentation(raw: ?ObjectMap, docs: ?Spec.ExternalDocumentation) !void {
    if (raw) |object| {
        const parsed = docs orelse return error.MissingField;
        try expectPresentOrDefaultString(object, "url", parsed.url);
        try expectOptionalString(object, "description", parsed.description);
    } else {
        try std.testing.expect(docs == null);
    }
}

fn compareServers(raw: ?[]const Value, servers: []const Spec.Server) !void {
    try std.testing.expectEqual(jsonArrayLen(raw), servers.len);
    if (raw) |items| {
        for (items, servers) |value, server| {
            try compareServer(try expectObject(value), server);
        }
    }
}

fn compareServer(raw: ObjectMap, server: Spec.Server) !void {
    try expectPresentOrDefaultString(raw, "url", server.url);
    try expectOptionalString(raw, "description", server.description);
    try compareServerVariables(try optionalObject(raw.get("variables")), server.variables);
}

fn compareServerVariables(raw: ?ObjectMap, variables: []const Spec.Named(Spec.ServerVariable)) !void {
    try expectEqualMapCount(raw, variables.len);
    if (raw) |object| {
        for (object.keys(), object.values()) |name, value| {
            const parsed = Spec.findNamed(Spec.ServerVariable, variables, name) orelse return error.MissingField;
            try compareServerVariable(try expectObject(value), parsed);
        }
    }
}

fn compareServerVariable(raw: ObjectMap, variable: Spec.ServerVariable) !void {
    try expectPresentOrDefaultString(raw, "default", variable.default_value);
    try expectOptionalString(raw, "description", variable.description);
    try std.testing.expectEqual(jsonArrayLen(try optionalArray(raw.get("enum"))), variable.enum_values.len);
}

fn compareTags(raw: ?[]const Value, tags: []const Spec.Tag) !void {
    try std.testing.expectEqual(jsonArrayLen(raw), tags.len);
    if (raw) |items| {
        for (items, tags) |value, tag| {
            const object = try expectObject(value);
            try expectPresentOrDefaultString(object, "name", tag.name);
            try expectOptionalString(object, "description", tag.description);
            try compareExternalDocumentation(try optionalObject(object.get("externalDocs")), tag.external_docs);
        }
    }
}

fn comparePaths(raw: ?ObjectMap, spec: Spec) !void {
    try expectEqualMapCount(raw, spec.paths.len);
    if (raw) |object| {
        for (object.keys(), object.values()) |name, value| {
            const parsed = spec.findPath(name) orelse return error.MissingField;
            try comparePathItemOrRef(value, parsed);
        }
    }
}

fn comparePathItemOrRef(raw: Value, item: Spec.PathItemOrRef) anyerror!void {
    const object = try expectObject(raw);
    if (isReferenceObject(object)) {
        switch (item) {
            .reference => |reference| try compareReference(object, reference),
            .path_item => return error.ExpectedReference,
        }
        return;
    }

    switch (item) {
        .reference => return error.UnexpectedReference,
        .path_item => |path_item| try comparePathItem(object, path_item),
    }
}

fn comparePathItem(raw: ObjectMap, item: Spec.PathItem) anyerror!void {
    try expectOptionalString(raw, "summary", item.summary);
    try expectOptionalString(raw, "description", item.description);
    try compareServers(try optionalArray(raw.get("servers")), item.servers);
    try compareParameterArray(try optionalArray(raw.get("parameters")), item.parameters);

    try compareOptionalOperation(raw.get("get"), item.get);
    try compareOptionalOperation(raw.get("put"), item.put);
    try compareOptionalOperation(raw.get("post"), item.post);
    try compareOptionalOperation(raw.get("delete"), item.delete);
    try compareOptionalOperation(raw.get("options"), item.options);
    try compareOptionalOperation(raw.get("head"), item.head);
    try compareOptionalOperation(raw.get("patch"), item.patch);
    try compareOptionalOperation(raw.get("trace"), item.trace);
}

fn compareOptionalOperation(raw: ?Value, operation: ?Spec.Operation) anyerror!void {
    if (raw) |value| {
        if (value == .null) {
            try std.testing.expect(operation == null);
            return;
        }
        const parsed = operation orelse return error.MissingField;
        try compareOperation(try expectObject(value), parsed);
    } else {
        try std.testing.expect(operation == null);
    }
}

fn compareOperation(raw: ObjectMap, operation: Spec.Operation) anyerror!void {
    try compareStringArray(try optionalArray(raw.get("tags")), operation.tags);
    try expectOptionalString(raw, "summary", operation.summary);
    try expectOptionalString(raw, "description", operation.description);
    try expectOptionalString(raw, "operationId", operation.operation_id);
    try expectBoolDefaultFalse(raw, "deprecated", operation.deprecated);
    try compareExternalDocumentation(try optionalObject(raw.get("externalDocs")), operation.external_docs);
    try compareParameterArray(try optionalArray(raw.get("parameters")), operation.parameters);
    try compareRequestBodyOptional(raw.get("requestBody"), operation.request_body);
    try compareNamedResponseMap(try optionalObject(raw.get("responses")), operation.responses);
    try compareNamedCallbackMap(try optionalObject(raw.get("callbacks")), operation.callbacks);
    try compareSecurityRequirements(try optionalArray(raw.get("security")), operation.security);
    try compareServers(try optionalArray(raw.get("servers")), operation.servers);
}

fn compareParameterArray(raw: ?[]const Value, parameters: []const Spec.ParameterOrRef) anyerror!void {
    try std.testing.expectEqual(jsonArrayLen(raw), parameters.len);
    if (raw) |items| {
        for (items, parameters) |value, parameter| {
            try compareParameterOrRef(value, parameter);
        }
    }
}

fn compareParameterOrRef(raw: Value, parameter: Spec.ParameterOrRef) anyerror!void {
    const object = try expectObject(raw);
    if (isReferenceObject(object)) {
        switch (parameter) {
            .reference => |reference| try compareReference(object, reference),
            .parameter => return error.ExpectedReference,
        }
        return;
    }

    switch (parameter) {
        .reference => return error.UnexpectedReference,
        .parameter => |value| try compareParameter(object, value),
    }
}

fn compareParameter(raw: ObjectMap, parameter: Spec.Parameter) anyerror!void {
    try expectPresentOrDefaultString(raw, "name", parameter.name);
    try expectPresentOrDefaultString(raw, "in", @tagName(parameter.location));
    try expectOptionalString(raw, "description", parameter.description);
    try expectBoolDefaultFalse(raw, "required", parameter.required);
    try expectBoolDefaultFalse(raw, "deprecated", parameter.deprecated);
    try expectBoolDefaultFalse(raw, "allowEmptyValue", parameter.allow_empty_value);
    try expectOptionalString(raw, "style", parameter.style);
    try expectOptionalBool(raw, "explode", parameter.explode);
    try expectBoolDefaultFalse(raw, "allowReserved", parameter.allow_reserved);
    try compareSchemaPointerOptional(raw.get("schema"), parameter.schema);
    try compareLiteralOptional(raw.get("example"), parameter.example);
    try compareNamedMediaTypeMap(try optionalObject(raw.get("content")), parameter.content);
}

fn compareRequestBodyOptional(raw: ?Value, request_body: ?Spec.RequestBodyOrRef) anyerror!void {
    if (raw) |value| {
        if (value == .null) {
            try std.testing.expect(request_body == null);
            return;
        }
        const parsed = request_body orelse return error.MissingField;
        try compareRequestBodyOrRef(value, parsed);
    } else {
        try std.testing.expect(request_body == null);
    }
}

fn compareRequestBodyOrRef(raw: Value, request_body: Spec.RequestBodyOrRef) anyerror!void {
    const object = try expectObject(raw);
    if (isReferenceObject(object)) {
        switch (request_body) {
            .reference => |reference| try compareReference(object, reference),
            .request_body => return error.ExpectedReference,
        }
        return;
    }

    switch (request_body) {
        .reference => return error.UnexpectedReference,
        .request_body => |value| {
            try expectOptionalString(object, "description", value.description);
            try expectBoolDefaultFalse(object, "required", value.required);
            try compareNamedMediaTypeMap(try optionalObject(object.get("content")), value.content);
        },
    }
}

fn compareNamedResponseMap(raw: ?ObjectMap, responses: []const Spec.Named(Spec.ResponseOrRef)) anyerror!void {
    try expectEqualMapCount(raw, responses.len);
    if (raw) |object| {
        for (object.keys(), object.values()) |name, value| {
            const parsed = Spec.findNamed(Spec.ResponseOrRef, responses, name) orelse return error.MissingField;
            try compareResponseOrRef(value, parsed);
        }
    }
}

fn compareResponseOrRef(raw: Value, response: Spec.ResponseOrRef) anyerror!void {
    const object = try expectObject(raw);
    if (isReferenceObject(object)) {
        switch (response) {
            .reference => |reference| try compareReference(object, reference),
            .response => return error.ExpectedReference,
        }
        return;
    }

    switch (response) {
        .reference => return error.UnexpectedReference,
        .response => |value| {
            try expectPresentOrDefaultString(object, "description", value.description);
            try compareNamedHeaderMap(try optionalObject(object.get("headers")), value.headers);
            try compareNamedMediaTypeMap(try optionalObject(object.get("content")), value.content);
            try compareNamedLinkMap(try optionalObject(object.get("links")), value.links);
        },
    }
}

fn compareNamedHeaderMap(raw: ?ObjectMap, headers: []const Spec.Named(Spec.HeaderOrRef)) anyerror!void {
    try expectEqualMapCount(raw, headers.len);
    if (raw) |object| {
        for (object.keys(), object.values()) |name, value| {
            const parsed = Spec.findNamed(Spec.HeaderOrRef, headers, name) orelse return error.MissingField;
            try compareHeaderOrRef(value, parsed);
        }
    }
}

fn compareHeaderOrRef(raw: Value, header: Spec.HeaderOrRef) anyerror!void {
    const object = try expectObject(raw);
    if (isReferenceObject(object)) {
        switch (header) {
            .reference => |reference| try compareReference(object, reference),
            .header => return error.ExpectedReference,
        }
        return;
    }

    switch (header) {
        .reference => return error.UnexpectedReference,
        .header => |value| {
            try expectOptionalString(object, "description", value.description);
            try expectBoolDefaultFalse(object, "required", value.required);
            try expectBoolDefaultFalse(object, "deprecated", value.deprecated);
            try expectBoolDefaultFalse(object, "allowEmptyValue", value.allow_empty_value);
            try expectOptionalString(object, "style", value.style);
            try expectOptionalBool(object, "explode", value.explode);
            try expectBoolDefaultFalse(object, "allowReserved", value.allow_reserved);
            try compareSchemaPointerOptional(object.get("schema"), value.schema);
            try compareLiteralOptional(object.get("example"), value.example);
            try compareNamedMediaTypeMap(try optionalObject(object.get("content")), value.content);
        },
    }
}

fn compareNamedMediaTypeMap(raw: ?ObjectMap, media_types: []const Spec.Named(Spec.MediaType)) anyerror!void {
    try expectEqualMapCount(raw, media_types.len);
    if (raw) |object| {
        for (object.keys(), object.values()) |name, value| {
            const parsed = Spec.findNamed(Spec.MediaType, media_types, name) orelse return error.MissingField;
            try compareMediaType(try expectObject(value), parsed);
        }
    }
}

fn compareMediaType(raw: ObjectMap, media_type: Spec.MediaType) anyerror!void {
    try compareSchemaPointerOptional(raw.get("schema"), media_type.schema);
    try compareLiteralOptional(raw.get("example"), media_type.example);
    try compareNamedExampleMap(try optionalObject(raw.get("examples")), media_type.examples);
    try compareNamedEncodingMap(try optionalObject(raw.get("encoding")), media_type.encoding);
}

fn compareNamedEncodingMap(raw: ?ObjectMap, encodings: []const Spec.Named(Spec.Encoding)) anyerror!void {
    try expectEqualMapCount(raw, encodings.len);
    if (raw) |object| {
        for (object.keys(), object.values()) |name, value| {
            const parsed = Spec.findNamed(Spec.Encoding, encodings, name) orelse return error.MissingField;
            try compareEncoding(try expectObject(value), parsed);
        }
    }
}

fn compareEncoding(raw: ObjectMap, encoding: Spec.Encoding) anyerror!void {
    try expectOptionalString(raw, "contentType", encoding.content_type);
    try compareNamedHeaderMap(try optionalObject(raw.get("headers")), encoding.headers);
    try expectOptionalString(raw, "style", encoding.style);
    try expectOptionalBool(raw, "explode", encoding.explode);
    try expectBoolDefaultFalse(raw, "allowReserved", encoding.allow_reserved);
}

fn compareComponents(raw: ?ObjectMap, components: ?Spec.Components) anyerror!void {
    if (raw) |object| {
        const parsed = components orelse return error.MissingField;
        try compareNamedSchemaMap(try optionalObject(object.get("schemas")), parsed.schemas);
        try compareNamedResponseMap(try optionalObject(object.get("responses")), parsed.responses);
        try compareNamedParameterMap(try optionalObject(object.get("parameters")), parsed.parameters);
        try compareNamedExampleMap(try optionalObject(object.get("examples")), parsed.examples);
        try compareNamedRequestBodyMap(try optionalObject(object.get("requestBodies")), parsed.request_bodies);
        try compareNamedHeaderMap(try optionalObject(object.get("headers")), parsed.headers);
        try compareNamedSecuritySchemeMap(try optionalObject(object.get("securitySchemes")), parsed.security_schemes);
        try compareNamedLinkMap(try optionalObject(object.get("links")), parsed.links);
        try compareNamedCallbackMap(try optionalObject(object.get("callbacks")), parsed.callbacks);
    } else {
        try std.testing.expect(components == null);
    }
}

fn compareNamedSchemaMap(raw: ?ObjectMap, schemas: []const Spec.Named(Spec.SchemaOrRef)) anyerror!void {
    try expectEqualMapCount(raw, schemas.len);
    if (raw) |object| {
        for (object.keys(), object.values()) |name, value| {
            const parsed = Spec.findNamed(Spec.SchemaOrRef, schemas, name) orelse return error.MissingField;
            try compareSchemaOrRef(value, parsed);
        }
    }
}

fn compareSchemaPointerOptional(raw: ?Value, schema: ?*const Spec.SchemaOrRef) anyerror!void {
    if (raw) |value| {
        if (value == .null) {
            try std.testing.expect(schema == null);
            return;
        }
        const parsed = schema orelse return error.MissingField;
        try compareSchemaOrRef(value, parsed.*);
    } else {
        try std.testing.expect(schema == null);
    }
}

fn compareSchemaOrRef(raw: Value, schema: Spec.SchemaOrRef) anyerror!void {
    const object = try expectObject(raw);
    if (isReferenceObject(object)) {
        switch (schema) {
            .reference => |reference| try compareReference(object, reference),
            .schema => return error.ExpectedReference,
        }
        return;
    }

    switch (schema) {
        .reference => return error.UnexpectedReference,
        .schema => |value| try compareSchema(object, value),
    }
}

fn compareSchema(raw: ObjectMap, schema: Spec.Schema) anyerror!void {
    try expectOptionalString(raw, "title", schema.title);
    try expectOptionalString(raw, "pattern", schema.pattern);
    try expectOptionalString(raw, "description", schema.description);
    try expectOptionalString(raw, "format", schema.format);
    try expectOptionalString(raw, "type", schema.schema_type);
    try expectBoolDefaultFalse(raw, "nullable", schema.nullable);
    try expectBoolDefaultFalse(raw, "readOnly", schema.read_only);
    try expectBoolDefaultFalse(raw, "writeOnly", schema.write_only);
    try expectBoolDefaultFalse(raw, "deprecated", schema.deprecated);
    try expectBoolDefaultFalse(raw, "uniqueItems", schema.unique_items);
    try compareStringArray(try optionalArray(raw.get("required")), schema.required);
    try std.testing.expectEqual(jsonArrayLen(try optionalArray(raw.get("enum"))), schema.enum_values.len);
    try compareSchemaArray(try optionalArray(raw.get("allOf")), schema.all_of);
    try compareSchemaArray(try optionalArray(raw.get("oneOf")), schema.one_of);
    try compareSchemaArray(try optionalArray(raw.get("anyOf")), schema.any_of);
    try compareSchemaPointerOptional(raw.get("items"), schema.items);
    try compareNamedSchemaMap(try optionalObject(raw.get("properties")), schema.properties);
    try compareAdditionalProperties(raw.get("additionalProperties"), schema.additional_properties);
    try compareDiscriminator(try optionalObject(raw.get("discriminator")), schema.discriminator);
    try compareXml(try optionalObject(raw.get("xml")), schema.xml);
    try compareLiteralOptional(raw.get("default"), schema.default);
    try compareLiteralOptional(raw.get("example"), schema.example);
}

fn compareSchemaArray(raw: ?[]const Value, items: []const Spec.SchemaOrRef) anyerror!void {
    try std.testing.expectEqual(jsonArrayLen(raw), items.len);
    if (raw) |values| {
        for (values, items) |value, item| {
            try compareSchemaOrRef(value, item);
        }
    }
}

fn compareAdditionalProperties(raw: ?Value, additional_properties: ?Spec.AdditionalProperties) anyerror!void {
    if (raw) |value| {
        const parsed = additional_properties orelse return error.MissingField;
        switch (value) {
            .bool => |bool_value| switch (parsed) {
                .boolean => |actual| try std.testing.expectEqual(bool_value, actual),
                .schema => return error.ExpectedBoolean,
            },
            .object => switch (parsed) {
                .boolean => return error.ExpectedObject,
                .schema => |schema| try compareSchemaOrRef(value, schema.*),
            },
            else => return error.ExpectedObject,
        }
    } else {
        try std.testing.expect(additional_properties == null);
    }
}

fn compareDiscriminator(raw: ?ObjectMap, discriminator: ?Spec.Discriminator) !void {
    if (raw) |object| {
        const parsed = discriminator orelse return error.MissingField;
        try expectPresentOrDefaultString(object, "propertyName", parsed.property_name);
        try compareNamedStringMap(try optionalObject(object.get("mapping")), parsed.mapping);
    } else {
        try std.testing.expect(discriminator == null);
    }
}

fn compareXml(raw: ?ObjectMap, xml: ?Spec.Xml) !void {
    if (raw) |object| {
        const parsed = xml orelse return error.MissingField;
        try expectOptionalString(object, "name", parsed.name);
        try expectOptionalString(object, "namespace", parsed.namespace);
        try expectOptionalString(object, "prefix", parsed.prefix);
        try expectBoolDefaultFalse(object, "attribute", parsed.attribute);
        try expectBoolDefaultFalse(object, "wrapped", parsed.wrapped);
    } else {
        try std.testing.expect(xml == null);
    }
}

fn compareNamedParameterMap(raw: ?ObjectMap, parameters: []const Spec.Named(Spec.ParameterOrRef)) anyerror!void {
    try expectEqualMapCount(raw, parameters.len);
    if (raw) |object| {
        for (object.keys(), object.values()) |name, value| {
            const parsed = Spec.findNamed(Spec.ParameterOrRef, parameters, name) orelse return error.MissingField;
            try compareParameterOrRef(value, parsed);
        }
    }
}

fn compareNamedRequestBodyMap(raw: ?ObjectMap, request_bodies: []const Spec.Named(Spec.RequestBodyOrRef)) anyerror!void {
    try expectEqualMapCount(raw, request_bodies.len);
    if (raw) |object| {
        for (object.keys(), object.values()) |name, value| {
            const parsed = Spec.findNamed(Spec.RequestBodyOrRef, request_bodies, name) orelse return error.MissingField;
            try compareRequestBodyOrRef(value, parsed);
        }
    }
}

fn compareNamedExampleMap(raw: ?ObjectMap, examples: []const Spec.Named(Spec.ExampleOrRef)) anyerror!void {
    try expectEqualMapCount(raw, examples.len);
    if (raw) |object| {
        for (object.keys(), object.values()) |name, value| {
            const parsed = Spec.findNamed(Spec.ExampleOrRef, examples, name) orelse return error.MissingField;
            try compareExampleOrRef(value, parsed);
        }
    }
}

fn compareExampleOrRef(raw: Value, example: Spec.ExampleOrRef) anyerror!void {
    const object = try expectObject(raw);
    if (isReferenceObject(object)) {
        switch (example) {
            .reference => |reference| try compareReference(object, reference),
            .example => return error.ExpectedReference,
        }
        return;
    }

    switch (example) {
        .reference => return error.UnexpectedReference,
        .example => |value| {
            try expectOptionalString(object, "summary", value.summary);
            try expectOptionalString(object, "description", value.description);
            try expectOptionalString(object, "externalValue", value.external_value);
            try compareLiteralOptional(object.get("value"), value.value);
        },
    }
}

fn compareNamedLinkMap(raw: ?ObjectMap, links: []const Spec.Named(Spec.LinkOrRef)) anyerror!void {
    try expectEqualMapCount(raw, links.len);
    if (raw) |object| {
        for (object.keys(), object.values()) |name, value| {
            const parsed = Spec.findNamed(Spec.LinkOrRef, links, name) orelse return error.MissingField;
            try compareLinkOrRef(value, parsed);
        }
    }
}

fn compareLinkOrRef(raw: Value, link: Spec.LinkOrRef) anyerror!void {
    const object = try expectObject(raw);
    if (isReferenceObject(object)) {
        switch (link) {
            .reference => |reference| try compareReference(object, reference),
            .link => return error.ExpectedReference,
        }
        return;
    }

    switch (link) {
        .reference => return error.UnexpectedReference,
        .link => |value| {
            try expectOptionalString(object, "operationRef", value.operation_ref);
            try expectOptionalString(object, "operationId", value.operation_id);
            try expectOptionalString(object, "description", value.description);
            try compareNamedLiteralMap(try optionalObject(object.get("parameters")), value.parameters);
            try compareLiteralOptional(object.get("requestBody"), value.request_body);
            try compareServerOptional(object.get("server"), value.server);
        },
    }
}

fn compareServerOptional(raw: ?Value, server: ?Spec.Server) anyerror!void {
    if (raw) |value| {
        if (value == .null) {
            try std.testing.expect(server == null);
            return;
        }
        const parsed = server orelse return error.MissingField;
        try compareServer(try expectObject(value), parsed);
    } else {
        try std.testing.expect(server == null);
    }
}

fn compareNamedLiteralMap(raw: ?ObjectMap, items: []const Spec.Named(Spec.Literal)) anyerror!void {
    try expectEqualMapCount(raw, items.len);
    if (raw) |object| {
        for (object.keys(), object.values()) |name, value| {
            const parsed = Spec.findNamed(Spec.Literal, items, name) orelse return error.MissingField;
            try compareLiteral(value, parsed);
        }
    }
}

fn compareNamedCallbackMap(raw: ?ObjectMap, callbacks: []const Spec.Named(Spec.CallbackOrRef)) anyerror!void {
    try expectEqualMapCount(raw, callbacks.len);
    if (raw) |object| {
        for (object.keys(), object.values()) |name, value| {
            const parsed = Spec.findNamed(Spec.CallbackOrRef, callbacks, name) orelse return error.MissingField;
            try compareCallbackOrRef(value, parsed);
        }
    }
}

fn compareCallbackOrRef(raw: Value, callback: Spec.CallbackOrRef) anyerror!void {
    const object = try expectObject(raw);
    if (isReferenceObject(object)) {
        switch (callback) {
            .reference => |reference| try compareReference(object, reference),
            .callback => return error.ExpectedReference,
        }
        return;
    }

    switch (callback) {
        .reference => return error.UnexpectedReference,
        .callback => |value| {
            try std.testing.expectEqual(object.count(), value.expressions.len);
            for (object.keys(), object.values()) |name, expression| {
                const parsed = Spec.findNamed(Spec.PathItemOrRef, value.expressions, name) orelse return error.MissingField;
                try comparePathItemOrRef(expression, parsed);
            }
        },
    }
}

fn compareNamedSecuritySchemeMap(raw: ?ObjectMap, schemes: []const Spec.Named(Spec.SecuritySchemeOrRef)) anyerror!void {
    try expectEqualMapCount(raw, schemes.len);
    if (raw) |object| {
        for (object.keys(), object.values()) |name, value| {
            const parsed = Spec.findNamed(Spec.SecuritySchemeOrRef, schemes, name) orelse return error.MissingField;
            try compareSecuritySchemeOrRef(value, parsed);
        }
    }
}

fn compareSecuritySchemeOrRef(raw: Value, scheme: Spec.SecuritySchemeOrRef) anyerror!void {
    const object = try expectObject(raw);
    if (isReferenceObject(object)) {
        switch (scheme) {
            .reference => |reference| try compareReference(object, reference),
            .security_scheme => return error.ExpectedReference,
        }
        return;
    }

    switch (scheme) {
        .reference => return error.UnexpectedReference,
        .security_scheme => |value| {
            try expectPresentOrDefaultString(object, "type", value.kind);
            try expectOptionalString(object, "description", value.description);
            try expectOptionalString(object, "name", value.name);
            try expectOptionalString(object, "in", value.location);
            try expectOptionalString(object, "scheme", value.scheme);
            try expectOptionalString(object, "bearerFormat", value.bearer_format);
            try expectOptionalString(object, "openIdConnectUrl", value.open_id_connect_url);
        },
    }
}

fn compareSecurityRequirements(raw: ?[]const Value, requirements: []const Spec.SecurityRequirement) anyerror!void {
    try std.testing.expectEqual(jsonArrayLen(raw), requirements.len);
    if (raw) |items| {
        for (items, requirements) |value, requirement| {
            try compareSecurityRequirement(try expectObject(value), requirement);
        }
    }
}

fn compareSecurityRequirement(raw: ObjectMap, requirement: Spec.SecurityRequirement) anyerror!void {
    try std.testing.expectEqual(raw.count(), requirement.items.len);
    for (raw.keys(), raw.values()) |name, value| {
        const item = findSecurityRequirementItem(requirement.items, name) orelse return error.MissingField;
        try compareStringArray(try optionalArray(@as(?Value, value)), item.scopes);
    }
}

fn findSecurityRequirementItem(items: []const Spec.SecurityRequirementItem, name: []const u8) ?Spec.SecurityRequirementItem {
    for (items) |item| {
        if (std.mem.eql(u8, item.name, name)) return item;
    }
    return null;
}

fn compareReference(raw: ObjectMap, reference: Spec.Reference) anyerror!void {
    try expectPresentOrDefaultString(raw, "$ref", reference.ref_path);
    try expectOptionalString(raw, "summary", reference.summary);
    try expectOptionalString(raw, "description", reference.description);
}

fn compareNamedStringMap(raw: ?ObjectMap, items: []const Spec.Named([]const u8)) anyerror!void {
    try expectEqualMapCount(raw, items.len);
    if (raw) |object| {
        for (object.keys(), object.values()) |name, value| {
            const parsed = Spec.findNamed([]const u8, items, name) orelse return error.MissingField;
            try std.testing.expectEqualStrings(try expectString(value), parsed);
        }
    }
}

fn compareLiteralOptional(raw: ?Value, literal: ?Spec.Literal) anyerror!void {
    if (raw) |value| {
        if (value == .null and literal == null) return;
        const parsed = literal orelse return error.MissingField;
        try compareLiteral(value, parsed);
    } else {
        try std.testing.expect(literal == null);
    }
}

fn compareLiteral(raw: Value, literal: Spec.Literal) anyerror!void {
    switch (literal) {
        .null => try std.testing.expect(raw == .null),
        .bool => |value| switch (raw) {
            .bool => |actual| try std.testing.expectEqual(value, actual),
            else => return error.ExpectedBoolean,
        },
        .integer => |value| switch (raw) {
            .integer => |actual| try std.testing.expectEqual(value, actual),
            else => return error.ExpectedInteger,
        },
        .float => |value| switch (raw) {
            .float => |actual| try std.testing.expectEqual(value, actual),
            .integer => |actual| try std.testing.expectEqual(value, @as(f64, @floatFromInt(actual))),
            else => return error.ExpectedFloat,
        },
        .string => |value| try std.testing.expectEqualStrings(value, try expectString(raw)),
        .array => |items| {
            const raw_items = try expectArray(raw);
            try std.testing.expectEqual(raw_items.len, items.len);
            for (raw_items, items) |raw_item, item| {
                try compareLiteral(raw_item, item);
            }
        },
        .object => |items| {
            const raw_object = try expectObject(raw);
            try std.testing.expectEqual(raw_object.count(), items.len);
            for (raw_object.keys(), raw_object.values()) |name, value| {
                const parsed = Spec.findNamed(Spec.Literal, items, name) orelse return error.MissingField;
                try compareLiteral(value, parsed);
            }
        },
    }
}

fn compareStringArray(raw: ?[]const Value, items: []const []const u8) anyerror!void {
    try std.testing.expectEqual(jsonArrayLen(raw), items.len);
    if (raw) |values| {
        for (values, items) |value, item| {
            try std.testing.expectEqualStrings(try expectString(value), item);
        }
    }
}

fn expectPresentOrDefaultString(raw: ObjectMap, name: []const u8, actual: []const u8) !void {
    if (raw.get(name)) |value| {
        if (value == .null) {
            try std.testing.expectEqualStrings("", actual);
            return;
        }
        try std.testing.expectEqualStrings(try expectString(value), actual);
    } else {
        try std.testing.expectEqualStrings("", actual);
    }
}

fn expectOptionalString(raw: ObjectMap, name: []const u8, actual: ?[]const u8) !void {
    if (raw.get(name)) |value| {
        if (value == .null) {
            try std.testing.expect(actual == null);
            return;
        }
        const parsed = actual orelse return error.MissingField;
        try std.testing.expectEqualStrings(try expectString(value), parsed);
    } else {
        try std.testing.expect(actual == null);
    }
}

fn expectBoolDefaultFalse(raw: ObjectMap, name: []const u8, actual: bool) !void {
    if (raw.get(name)) |value| {
        if (value == .null) {
            try std.testing.expect(!actual);
            return;
        }
        try std.testing.expectEqual(try expectBool(value), actual);
    } else {
        try std.testing.expect(!actual);
    }
}

fn expectOptionalBool(raw: ObjectMap, name: []const u8, actual: ?bool) !void {
    if (raw.get(name)) |value| {
        if (value == .null) {
            try std.testing.expect(actual == null);
            return;
        }
        const parsed = actual orelse return error.MissingField;
        try std.testing.expectEqual(try expectBool(value), parsed);
    } else {
        try std.testing.expect(actual == null);
    }
}

fn expectEqualMapCount(raw: ?ObjectMap, expected: usize) !void {
    try std.testing.expectEqual(jsonMapCount(raw), expected);
}

fn jsonMapCount(raw: ?ObjectMap) usize {
    return if (raw) |object| object.count() else 0;
}

fn jsonArrayLen(raw: ?[]const Value) usize {
    return if (raw) |items| items.len else 0;
}

fn optionalObject(value: ?Value) !?ObjectMap {
    if (value == null or value.? == .null) return null;
    return try expectObject(value.?);
}

fn optionalArray(value: ?Value) !?[]const Value {
    if (value == null or value.? == .null) return null;
    return try expectArray(value.?);
}

fn expectObject(value: Value) !ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => error.ExpectedObject,
    };
}

fn expectArray(value: Value) ![]const Value {
    return switch (value) {
        .array => |array| array.items,
        else => error.ExpectedArray,
    };
}

fn expectString(value: Value) ![]const u8 {
    return switch (value) {
        .string => |string| string,
        else => error.ExpectedString,
    };
}

fn expectBool(value: Value) !bool {
    return switch (value) {
        .bool => |boolean| boolean,
        else => error.ExpectedBoolean,
    };
}

fn isReferenceObject(object: ObjectMap) bool {
    return object.get("$ref") != null;
}
