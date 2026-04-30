const std = @import("std");
const Spec = @import("../Spec.zig");

const Allocator = std.mem.Allocator;
const IoWriter = std.Io.Writer;

pub fn stringifyAlloc(allocator: Allocator, spec: Spec) ![]u8 {
    var out: std.io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    var ctx = StringifyContext{
        .allocator = allocator,
        .writer = &out.writer,
    };
    try ctx.writeSpec(spec);

    return try allocator.dupe(u8, out.written());
}

const StringifyContext = struct {
    allocator: Allocator,
    writer: *IoWriter,

    const Self = @This();

    fn writeSpec(self: *Self, spec: Spec) !void {
        try self.writer.writeAll("{");
        var first = true;

        try self.writeFieldName(&first, "info");
        try self.writeInfo(spec.info);

        try self.writeStringField(&first, "openapi", spec.openapi);

        try self.writeFieldName(&first, "paths");
        try self.writeNamedObjectMap(Spec.PathItemOrRef, spec.paths, writePathItemOrRef);

        if (spec.components) |components| {
            try self.writeFieldName(&first, "components");
            try self.writeComponents(components);
        }
        if (spec.external_docs) |docs| {
            try self.writeFieldName(&first, "externalDocs");
            try self.writeExternalDocumentation(docs);
        }
        if (spec.security.len != 0) {
            try self.writeFieldName(&first, "security");
            try self.writeSecurityRequirements(spec.security);
        }
        if (spec.servers.len != 0) {
            try self.writeFieldName(&first, "servers");
            try self.writeArray(Spec.Server, spec.servers, writeServer);
        }
        if (spec.tags.len != 0) {
            try self.writeFieldName(&first, "tags");
            try self.writeArray(Spec.Tag, spec.tags, writeTag);
        }

        try self.writer.writeAll("}");
    }

    fn writeInfo(self: *Self, info: Spec.Info) !void {
        try self.writer.writeAll("{");
        var first = true;

        try self.writeOptionalStringField(&first, "description", info.description);
        if (info.contact) |contact| {
            try self.writeFieldName(&first, "contact");
            try self.writeContact(contact);
        }
        if (info.license) |license| {
            try self.writeFieldName(&first, "license");
            try self.writeLicense(license);
        }
        try self.writeOptionalStringField(&first, "summary", info.summary);
        try self.writeOptionalStringField(&first, "termsOfService", info.terms_of_service);
        try self.writeStringField(&first, "title", info.title);
        try self.writeStringField(&first, "version", info.version);

        try self.writer.writeAll("}");
    }

    fn writeContact(self: *Self, contact: Spec.Contact) !void {
        try self.writer.writeAll("{");
        var first = true;
        try self.writeOptionalStringField(&first, "email", contact.email);
        try self.writeOptionalStringField(&first, "name", contact.name);
        try self.writeOptionalStringField(&first, "url", contact.url);
        try self.writer.writeAll("}");
    }

    fn writeLicense(self: *Self, license: Spec.License) !void {
        try self.writer.writeAll("{");
        var first = true;
        try self.writeOptionalStringField(&first, "identifier", license.identifier);
        try self.writeStringField(&first, "name", license.name);
        try self.writeOptionalStringField(&first, "url", license.url);
        try self.writer.writeAll("}");
    }

    fn writeExternalDocumentation(self: *Self, docs: Spec.ExternalDocumentation) !void {
        try self.writer.writeAll("{");
        var first = true;
        try self.writeOptionalStringField(&first, "description", docs.description);
        try self.writeStringField(&first, "url", docs.url);
        try self.writer.writeAll("}");
    }

    fn writeServer(self: *Self, server: Spec.Server) !void {
        try self.writer.writeAll("{");
        var first = true;
        try self.writeOptionalStringField(&first, "description", server.description);
        try self.writeStringField(&first, "url", server.url);
        if (server.variables.len != 0) {
            try self.writeFieldName(&first, "variables");
            try self.writeNamedObjectMap(Spec.ServerVariable, server.variables, writeServerVariable);
        }
        try self.writer.writeAll("}");
    }

    fn writeServerVariable(self: *Self, variable: Spec.ServerVariable) !void {
        try self.writer.writeAll("{");
        var first = true;
        try self.writeStringField(&first, "default", variable.default_value);
        if (variable.enum_values.len != 0) {
            try self.writeFieldName(&first, "enum");
            try self.writeStringArray(variable.enum_values);
        }
        try self.writeOptionalStringField(&first, "description", variable.description);
        try self.writer.writeAll("}");
    }

    fn writeTag(self: *Self, tag: Spec.Tag) !void {
        try self.writer.writeAll("{");
        var first = true;
        try self.writeOptionalStringField(&first, "description", tag.description);
        if (tag.external_docs) |docs| {
            try self.writeFieldName(&first, "externalDocs");
            try self.writeExternalDocumentation(docs);
        }
        try self.writeStringField(&first, "name", tag.name);
        try self.writer.writeAll("}");
    }

    fn writeComponents(self: *Self, components: Spec.Components) !void {
        try self.writer.writeAll("{");
        var first = true;

        if (components.callbacks.len != 0) {
            try self.writeFieldName(&first, "callbacks");
            try self.writeNamedObjectMap(Spec.CallbackOrRef, components.callbacks, writeCallbackOrRef);
        }
        if (components.examples.len != 0) {
            try self.writeFieldName(&first, "examples");
            try self.writeNamedObjectMap(Spec.ExampleOrRef, components.examples, writeExampleOrRef);
        }
        if (components.headers.len != 0) {
            try self.writeFieldName(&first, "headers");
            try self.writeNamedObjectMap(Spec.HeaderOrRef, components.headers, writeHeaderOrRef);
        }
        if (components.links.len != 0) {
            try self.writeFieldName(&first, "links");
            try self.writeNamedObjectMap(Spec.LinkOrRef, components.links, writeLinkOrRef);
        }
        if (components.parameters.len != 0) {
            try self.writeFieldName(&first, "parameters");
            try self.writeNamedObjectMap(Spec.ParameterOrRef, components.parameters, writeParameterOrRef);
        }
        if (components.request_bodies.len != 0) {
            try self.writeFieldName(&first, "requestBodies");
            try self.writeNamedObjectMap(Spec.RequestBodyOrRef, components.request_bodies, writeRequestBodyOrRef);
        }
        if (components.responses.len != 0) {
            try self.writeFieldName(&first, "responses");
            try self.writeNamedObjectMap(Spec.ResponseOrRef, components.responses, writeResponseOrRef);
        }
        if (components.schemas.len != 0) {
            try self.writeFieldName(&first, "schemas");
            try self.writeNamedObjectMap(Spec.SchemaOrRef, components.schemas, writeSchemaOrRef);
        }
        if (components.security_schemes.len != 0) {
            try self.writeFieldName(&first, "securitySchemes");
            try self.writeNamedObjectMap(Spec.SecuritySchemeOrRef, components.security_schemes, writeSecuritySchemeOrRef);
        }

        try self.writer.writeAll("}");
    }

    fn writePathItemOrRef(self: *Self, value: Spec.PathItemOrRef) !void {
        switch (value) {
            .path_item => |item| try self.writePathItem(item),
            .reference => |reference| try self.writeReference(reference),
        }
    }

    fn writePathItem(self: *Self, item: Spec.PathItem) !void {
        try self.writer.writeAll("{");
        var first = true;

        try self.writeOptionalStringField(&first, "description", item.description);
        if (item.delete) |operation| {
            try self.writeFieldName(&first, "delete");
            try self.writeOperation(operation);
        }
        if (item.get) |operation| {
            try self.writeFieldName(&first, "get");
            try self.writeOperation(operation);
        }
        if (item.head) |operation| {
            try self.writeFieldName(&first, "head");
            try self.writeOperation(operation);
        }
        if (item.options) |operation| {
            try self.writeFieldName(&first, "options");
            try self.writeOperation(operation);
        }
        if (item.parameters.len != 0) {
            try self.writeFieldName(&first, "parameters");
            try self.writeArray(Spec.ParameterOrRef, item.parameters, writeParameterOrRef);
        }
        if (item.patch) |operation| {
            try self.writeFieldName(&first, "patch");
            try self.writeOperation(operation);
        }
        if (item.post) |operation| {
            try self.writeFieldName(&first, "post");
            try self.writeOperation(operation);
        }
        if (item.put) |operation| {
            try self.writeFieldName(&first, "put");
            try self.writeOperation(operation);
        }
        if (item.servers.len != 0) {
            try self.writeFieldName(&first, "servers");
            try self.writeArray(Spec.Server, item.servers, writeServer);
        }
        try self.writeOptionalStringField(&first, "summary", item.summary);
        if (item.trace) |operation| {
            try self.writeFieldName(&first, "trace");
            try self.writeOperation(operation);
        }

        try self.writer.writeAll("}");
    }

    fn writeOperation(self: *Self, operation: Spec.Operation) !void {
        try self.writer.writeAll("{");
        var first = true;

        if (operation.callbacks.len != 0) {
            try self.writeFieldName(&first, "callbacks");
            try self.writeNamedObjectMap(Spec.CallbackOrRef, operation.callbacks, writeCallbackOrRef);
        }
        try self.writeOptionalBoolField(&first, "deprecated", operation.deprecated);
        try self.writeOptionalStringField(&first, "description", operation.description);
        if (operation.external_docs) |docs| {
            try self.writeFieldName(&first, "externalDocs");
            try self.writeExternalDocumentation(docs);
        }
        try self.writeOptionalStringField(&first, "operationId", operation.operation_id);
        if (operation.parameters.len != 0) {
            try self.writeFieldName(&first, "parameters");
            try self.writeArray(Spec.ParameterOrRef, operation.parameters, writeParameterOrRef);
        }
        if (operation.request_body) |body| {
            try self.writeFieldName(&first, "requestBody");
            try self.writeRequestBodyOrRef(body);
        }
        try self.writeFieldName(&first, "responses");
        try self.writeNamedObjectMap(Spec.ResponseOrRef, operation.responses, writeResponseOrRef);
        if (operation.security.len != 0) {
            try self.writeFieldName(&first, "security");
            try self.writeSecurityRequirements(operation.security);
        }
        if (operation.servers.len != 0) {
            try self.writeFieldName(&first, "servers");
            try self.writeArray(Spec.Server, operation.servers, writeServer);
        }
        try self.writeOptionalStringField(&first, "summary", operation.summary);
        if (operation.tags.len != 0) {
            try self.writeFieldName(&first, "tags");
            try self.writeStringArray(operation.tags);
        }

        try self.writer.writeAll("}");
    }

    fn writeParameterOrRef(self: *Self, value: Spec.ParameterOrRef) !void {
        switch (value) {
            .parameter => |parameter| try self.writeParameter(parameter),
            .reference => |reference| try self.writeReference(reference),
        }
    }

    fn writeParameter(self: *Self, parameter: Spec.Parameter) !void {
        try self.writer.writeAll("{");
        var first = true;

        try self.writeOptionalBoolField(&first, "allowEmptyValue", parameter.allow_empty_value);
        try self.writeOptionalBoolField(&first, "allowReserved", parameter.allow_reserved);
        if (parameter.content.len != 0) {
            try self.writeFieldName(&first, "content");
            try self.writeNamedObjectMap(Spec.MediaType, parameter.content, writeMediaType);
        }
        try self.writeOptionalBoolField(&first, "deprecated", parameter.deprecated);
        try self.writeOptionalStringField(&first, "description", parameter.description);
        if (parameter.example) |example| {
            try self.writeFieldName(&first, "example");
            try self.writeLiteral(example);
        }
        if (parameter.explode) |explode| {
            try self.writeFieldName(&first, "explode");
            try std.json.Stringify.value(explode, .{}, self.writer);
        }
        try self.writeFieldName(&first, "in");
        try std.json.Stringify.value(@tagName(parameter.location), .{}, self.writer);
        try self.writeStringField(&first, "name", parameter.name);
        try self.writeOptionalBoolField(&first, "required", parameter.required);
        if (parameter.schema) |schema| {
            try self.writeFieldName(&first, "schema");
            try self.writeSchemaOrRef(schema.*);
        }
        try self.writeOptionalStringField(&first, "style", parameter.style);

        try self.writer.writeAll("}");
    }

    fn writeRequestBodyOrRef(self: *Self, value: Spec.RequestBodyOrRef) !void {
        switch (value) {
            .request_body => |body| try self.writeRequestBody(body),
            .reference => |reference| try self.writeReference(reference),
        }
    }

    fn writeRequestBody(self: *Self, body: Spec.RequestBody) !void {
        try self.writer.writeAll("{");
        var first = true;
        if (body.content.len != 0) {
            try self.writeFieldName(&first, "content");
            try self.writeNamedObjectMap(Spec.MediaType, body.content, writeMediaType);
        }
        try self.writeOptionalStringField(&first, "description", body.description);
        try self.writeOptionalBoolField(&first, "required", body.required);
        try self.writer.writeAll("}");
    }

    fn writeResponseOrRef(self: *Self, value: Spec.ResponseOrRef) !void {
        switch (value) {
            .response => |response| try self.writeResponse(response),
            .reference => |reference| try self.writeReference(reference),
        }
    }

    fn writeResponse(self: *Self, response: Spec.Response) !void {
        try self.writer.writeAll("{");
        var first = true;
        if (response.content.len != 0) {
            try self.writeFieldName(&first, "content");
            try self.writeNamedObjectMap(Spec.MediaType, response.content, writeMediaType);
        }
        try self.writeStringField(&first, "description", response.description);
        if (response.headers.len != 0) {
            try self.writeFieldName(&first, "headers");
            try self.writeNamedObjectMap(Spec.HeaderOrRef, response.headers, writeHeaderOrRef);
        }
        if (response.links.len != 0) {
            try self.writeFieldName(&first, "links");
            try self.writeNamedObjectMap(Spec.LinkOrRef, response.links, writeLinkOrRef);
        }
        try self.writer.writeAll("}");
    }

    fn writeHeaderOrRef(self: *Self, value: Spec.HeaderOrRef) !void {
        switch (value) {
            .header => |header| try self.writeHeader(header),
            .reference => |reference| try self.writeReference(reference),
        }
    }

    fn writeHeader(self: *Self, header: Spec.Header) !void {
        try self.writer.writeAll("{");
        var first = true;

        try self.writeOptionalBoolField(&first, "allowEmptyValue", header.allow_empty_value);
        try self.writeOptionalBoolField(&first, "allowReserved", header.allow_reserved);
        if (header.content.len != 0) {
            try self.writeFieldName(&first, "content");
            try self.writeNamedObjectMap(Spec.MediaType, header.content, writeMediaType);
        }
        try self.writeOptionalBoolField(&first, "deprecated", header.deprecated);
        try self.writeOptionalStringField(&first, "description", header.description);
        if (header.example) |example| {
            try self.writeFieldName(&first, "example");
            try self.writeLiteral(example);
        }
        if (header.explode) |explode| {
            try self.writeFieldName(&first, "explode");
            try std.json.Stringify.value(explode, .{}, self.writer);
        }
        try self.writeOptionalBoolField(&first, "required", header.required);
        if (header.schema) |schema| {
            try self.writeFieldName(&first, "schema");
            try self.writeSchemaOrRef(schema.*);
        }
        try self.writeOptionalStringField(&first, "style", header.style);

        try self.writer.writeAll("}");
    }

    fn writeMediaType(self: *Self, media_type: Spec.MediaType) !void {
        try self.writer.writeAll("{");
        var first = true;

        if (media_type.encoding.len != 0) {
            try self.writeFieldName(&first, "encoding");
            try self.writeNamedObjectMap(Spec.Encoding, media_type.encoding, writeEncoding);
        }
        if (media_type.example) |example| {
            try self.writeFieldName(&first, "example");
            try self.writeLiteral(example);
        }
        if (media_type.examples.len != 0) {
            try self.writeFieldName(&first, "examples");
            try self.writeNamedObjectMap(Spec.ExampleOrRef, media_type.examples, writeExampleOrRef);
        }
        if (media_type.schema) |schema| {
            try self.writeFieldName(&first, "schema");
            try self.writeSchemaOrRef(schema.*);
        }

        try self.writer.writeAll("}");
    }

    fn writeEncoding(self: *Self, encoding: Spec.Encoding) !void {
        try self.writer.writeAll("{");
        var first = true;
        try self.writeOptionalBoolField(&first, "allowReserved", encoding.allow_reserved);
        try self.writeOptionalStringField(&first, "contentType", encoding.content_type);
        if (encoding.explode) |explode| {
            try self.writeFieldName(&first, "explode");
            try std.json.Stringify.value(explode, .{}, self.writer);
        }
        if (encoding.headers.len != 0) {
            try self.writeFieldName(&first, "headers");
            try self.writeNamedObjectMap(Spec.HeaderOrRef, encoding.headers, writeHeaderOrRef);
        }
        try self.writeOptionalStringField(&first, "style", encoding.style);
        try self.writer.writeAll("}");
    }

    fn writeSchemaOrRef(self: *Self, value: Spec.SchemaOrRef) anyerror!void {
        switch (value) {
            .schema => |schema| try self.writeSchema(schema),
            .reference => |reference| try self.writeReference(reference),
        }
    }

    fn writeSchema(self: *Self, schema: Spec.Schema) anyerror!void {
        try self.writer.writeAll("{");
        var first = true;

        if (schema.additional_properties) |additional_properties| {
            try self.writeFieldName(&first, "additionalProperties");
            try self.writeAdditionalProperties(additional_properties);
        }
        if (schema.all_of.len != 0) {
            try self.writeFieldName(&first, "allOf");
            try self.writeArray(Spec.SchemaOrRef, schema.all_of, writeSchemaOrRef);
        }
        if (schema.any_of.len != 0) {
            try self.writeFieldName(&first, "anyOf");
            try self.writeArray(Spec.SchemaOrRef, schema.any_of, writeSchemaOrRef);
        }
        if (schema.discriminator) |discriminator| {
            try self.writeFieldName(&first, "discriminator");
            try self.writeDiscriminator(discriminator);
        }
        try self.writeOptionalStringField(&first, "description", schema.description);
        if (schema.default) |default_value| {
            try self.writeFieldName(&first, "default");
            try self.writeLiteral(default_value);
        }
        try self.writeOptionalBoolField(&first, "deprecated", schema.deprecated);
        if (schema.enum_values.len != 0) {
            try self.writeFieldName(&first, "enum");
            try self.writeLiteralArray(schema.enum_values);
        }
        if (schema.example) |example| {
            try self.writeFieldName(&first, "example");
            try self.writeLiteral(example);
        }
        if (schema.exclusive_maximum) |exclusive_maximum| {
            try self.writeFieldName(&first, "exclusiveMaximum");
            try std.json.Stringify.value(exclusive_maximum, .{}, self.writer);
        }
        if (schema.exclusive_minimum) |exclusive_minimum| {
            try self.writeFieldName(&first, "exclusiveMinimum");
            try std.json.Stringify.value(exclusive_minimum, .{}, self.writer);
        }
        try self.writeOptionalStringField(&first, "format", schema.format);
        if (schema.items) |items| {
            try self.writeFieldName(&first, "items");
            try self.writeSchemaOrRef(items.*);
        }
        if (schema.max_items) |max_items| {
            try self.writeFieldName(&first, "maxItems");
            try std.json.Stringify.value(max_items, .{}, self.writer);
        }
        if (schema.max_length) |max_length| {
            try self.writeFieldName(&first, "maxLength");
            try std.json.Stringify.value(max_length, .{}, self.writer);
        }
        if (schema.max_properties) |max_properties| {
            try self.writeFieldName(&first, "maxProperties");
            try std.json.Stringify.value(max_properties, .{}, self.writer);
        }
        if (schema.maximum) |maximum| {
            try self.writeFieldName(&first, "maximum");
            try std.json.Stringify.value(maximum, .{}, self.writer);
        }
        if (schema.min_items) |min_items| {
            try self.writeFieldName(&first, "minItems");
            try std.json.Stringify.value(min_items, .{}, self.writer);
        }
        if (schema.min_length) |min_length| {
            try self.writeFieldName(&first, "minLength");
            try std.json.Stringify.value(min_length, .{}, self.writer);
        }
        if (schema.min_properties) |min_properties| {
            try self.writeFieldName(&first, "minProperties");
            try std.json.Stringify.value(min_properties, .{}, self.writer);
        }
        if (schema.minimum) |minimum| {
            try self.writeFieldName(&first, "minimum");
            try std.json.Stringify.value(minimum, .{}, self.writer);
        }
        if (schema.multiple_of) |multiple_of| {
            try self.writeFieldName(&first, "multipleOf");
            try std.json.Stringify.value(multiple_of, .{}, self.writer);
        }
        try self.writeOptionalBoolField(&first, "nullable", schema.nullable);
        if (schema.one_of.len != 0) {
            try self.writeFieldName(&first, "oneOf");
            try self.writeArray(Spec.SchemaOrRef, schema.one_of, writeSchemaOrRef);
        }
        try self.writeOptionalStringField(&first, "pattern", schema.pattern);
        if (schema.properties.len != 0) {
            try self.writeFieldName(&first, "properties");
            try self.writeNamedObjectMap(Spec.SchemaOrRef, schema.properties, writeSchemaOrRef);
        }
        try self.writeOptionalBoolField(&first, "readOnly", schema.read_only);
        if (schema.required.len != 0) {
            try self.writeFieldName(&first, "required");
            try self.writeStringArray(schema.required);
        }
        try self.writeOptionalStringField(&first, "title", schema.title);
        try self.writeOptionalStringField(&first, "type", schema.schema_type);
        try self.writeOptionalBoolField(&first, "uniqueItems", schema.unique_items);
        try self.writeOptionalBoolField(&first, "writeOnly", schema.write_only);
        if (schema.xml) |xml| {
            try self.writeFieldName(&first, "xml");
            try self.writeXml(xml);
        }

        try self.writer.writeAll("}");
    }

    fn writeAdditionalProperties(self: *Self, value: Spec.AdditionalProperties) anyerror!void {
        switch (value) {
            .boolean => |boolean| try std.json.Stringify.value(boolean, .{}, self.writer),
            .schema => |schema| try self.writeSchemaOrRef(schema.*),
        }
    }

    fn writeDiscriminator(self: *Self, discriminator: Spec.Discriminator) anyerror!void {
        try self.writer.writeAll("{");
        var first = true;
        try self.writeStringField(&first, "propertyName", discriminator.property_name);
        if (discriminator.mapping.len != 0) {
            try self.writeFieldName(&first, "mapping");
            try self.writeNamedObjectMap([]const u8, discriminator.mapping, writeRawString);
        }
        try self.writer.writeAll("}");
    }

    fn writeXml(self: *Self, xml: Spec.Xml) !void {
        try self.writer.writeAll("{");
        var first = true;
        try self.writeOptionalBoolField(&first, "attribute", xml.attribute);
        try self.writeOptionalStringField(&first, "name", xml.name);
        try self.writeOptionalStringField(&first, "namespace", xml.namespace);
        try self.writeOptionalStringField(&first, "prefix", xml.prefix);
        try self.writeOptionalBoolField(&first, "wrapped", xml.wrapped);
        try self.writer.writeAll("}");
    }

    fn writeExampleOrRef(self: *Self, value: Spec.ExampleOrRef) !void {
        switch (value) {
            .example => |example| try self.writeExample(example),
            .reference => |reference| try self.writeReference(reference),
        }
    }

    fn writeExample(self: *Self, example: Spec.Example) !void {
        try self.writer.writeAll("{");
        var first = true;
        try self.writeOptionalStringField(&first, "description", example.description);
        try self.writeOptionalStringField(&first, "externalValue", example.external_value);
        try self.writeOptionalStringField(&first, "summary", example.summary);
        if (example.value) |value| {
            try self.writeFieldName(&first, "value");
            try self.writeLiteral(value);
        }
        try self.writer.writeAll("}");
    }

    fn writeLinkOrRef(self: *Self, value: Spec.LinkOrRef) !void {
        switch (value) {
            .link => |link| try self.writeLink(link),
            .reference => |reference| try self.writeReference(reference),
        }
    }

    fn writeLink(self: *Self, link: Spec.Link) !void {
        try self.writer.writeAll("{");
        var first = true;
        try self.writeOptionalStringField(&first, "description", link.description);
        try self.writeOptionalStringField(&first, "operationId", link.operation_id);
        try self.writeOptionalStringField(&first, "operationRef", link.operation_ref);
        if (link.parameters.len != 0) {
            try self.writeFieldName(&first, "parameters");
            try self.writeNamedObjectMap(Spec.Literal, link.parameters, writeLiteralValue);
        }
        if (link.request_body) |request_body| {
            try self.writeFieldName(&first, "requestBody");
            try self.writeLiteral(request_body);
        }
        if (link.server) |server| {
            try self.writeFieldName(&first, "server");
            try self.writeServer(server);
        }
        try self.writer.writeAll("}");
    }

    fn writeCallbackOrRef(self: *Self, value: Spec.CallbackOrRef) !void {
        switch (value) {
            .callback => |callback| try self.writeCallback(callback),
            .reference => |reference| try self.writeReference(reference),
        }
    }

    fn writeCallback(self: *Self, callback: Spec.Callback) !void {
        try self.writeNamedObjectMap(Spec.PathItemOrRef, callback.expressions, writePathItemOrRef);
    }

    fn writeSecuritySchemeOrRef(self: *Self, value: Spec.SecuritySchemeOrRef) !void {
        switch (value) {
            .security_scheme => |scheme| try self.writeSecurityScheme(scheme),
            .reference => |reference| try self.writeReference(reference),
        }
    }

    fn writeSecurityScheme(self: *Self, scheme: Spec.SecurityScheme) !void {
        try self.writer.writeAll("{");
        var first = true;
        try self.writeOptionalStringField(&first, "bearerFormat", scheme.bearer_format);
        try self.writeOptionalStringField(&first, "description", scheme.description);
        if (scheme.flows) |flows| {
            try self.writeFieldName(&first, "flows");
            try self.writeOAuthFlows(flows);
        }
        try self.writeOptionalStringField(&first, "in", scheme.location);
        try self.writeOptionalStringField(&first, "name", scheme.name);
        try self.writeOptionalStringField(&first, "openIdConnectUrl", scheme.open_id_connect_url);
        try self.writeOptionalStringField(&first, "scheme", scheme.scheme);
        try self.writeStringField(&first, "type", scheme.kind);
        try self.writer.writeAll("}");
    }

    fn writeOAuthFlows(self: *Self, flows: Spec.OAuthFlows) !void {
        try self.writer.writeAll("{");
        var first = true;
        if (flows.authorization_code) |flow| {
            try self.writeFieldName(&first, "authorizationCode");
            try self.writeOAuthFlow(flow);
        }
        if (flows.client_credentials) |flow| {
            try self.writeFieldName(&first, "clientCredentials");
            try self.writeOAuthFlow(flow);
        }
        if (flows.implicit) |flow| {
            try self.writeFieldName(&first, "implicit");
            try self.writeOAuthFlow(flow);
        }
        if (flows.password) |flow| {
            try self.writeFieldName(&first, "password");
            try self.writeOAuthFlow(flow);
        }
        try self.writer.writeAll("}");
    }

    fn writeOAuthFlow(self: *Self, flow: Spec.OAuthFlow) !void {
        try self.writer.writeAll("{");
        var first = true;
        try self.writeOptionalStringField(&first, "authorizationUrl", flow.authorization_url);
        try self.writeOptionalStringField(&first, "refreshUrl", flow.refresh_url);
        if (flow.scopes.len != 0) {
            try self.writeFieldName(&first, "scopes");
            try self.writeScopes(flow.scopes);
        }
        try self.writeOptionalStringField(&first, "tokenUrl", flow.token_url);
        try self.writer.writeAll("}");
    }

    fn writeScopes(self: *Self, scopes: []const Spec.Scope) !void {
        try self.writer.writeAll("{");
        var first = true;
        const sorted = try self.allocator.dupe(Spec.Scope, scopes);
        defer self.allocator.free(sorted);
        sortScopes(sorted);
        for (sorted) |scope| {
            try self.writeFieldName(&first, scope.name);
            try std.json.Stringify.value(scope.description, .{}, self.writer);
        }
        try self.writer.writeAll("}");
    }

    fn writeSecurityRequirements(self: *Self, requirements: []const Spec.SecurityRequirement) !void {
        try self.writer.writeAll("[");
        for (requirements, 0..) |requirement, i| {
            if (i != 0) try self.writer.writeAll(",");
            try self.writeSecurityRequirement(requirement);
        }
        try self.writer.writeAll("]");
    }

    fn writeSecurityRequirement(self: *Self, requirement: Spec.SecurityRequirement) !void {
        try self.writer.writeAll("{");
        var first = true;
        const sorted = try self.allocator.dupe(Spec.SecurityRequirementItem, requirement.items);
        defer self.allocator.free(sorted);
        sortSecurityRequirementItems(sorted);
        for (sorted) |item| {
            try self.writeFieldName(&first, item.name);
            try self.writeStringArray(item.scopes);
        }
        try self.writer.writeAll("}");
    }

    fn writeReference(self: *Self, reference: Spec.Reference) !void {
        try self.writer.writeAll("{");
        var first = true;
        try self.writeStringField(&first, "$ref", reference.ref_path);
        try self.writeOptionalStringField(&first, "description", reference.description);
        try self.writeOptionalStringField(&first, "summary", reference.summary);
        try self.writer.writeAll("}");
    }

    fn writeLiteral(self: *Self, literal: Spec.Literal) anyerror!void {
        switch (literal) {
            .null => try self.writer.writeAll("null"),
            .bool => |bool_value| try std.json.Stringify.value(bool_value, .{}, self.writer),
            .integer => |integer_value| try std.json.Stringify.value(integer_value, .{}, self.writer),
            .float => |float_value| try std.json.Stringify.value(float_value, .{}, self.writer),
            .string => |string_value| try std.json.Stringify.value(string_value, .{}, self.writer),
            .array => |items| try self.writeLiteralArray(items),
            .object => |items| try self.writeNamedObjectMap(Spec.Literal, items, writeLiteralValue),
        }
    }

    fn writeLiteralValue(self: *Self, literal: Spec.Literal) anyerror!void {
        try self.writeLiteral(literal);
    }

    fn writeLiteralArray(self: *Self, literals: []const Spec.Literal) anyerror!void {
        try self.writer.writeAll("[");
        for (literals, 0..) |literal, i| {
            if (i != 0) try self.writer.writeAll(",");
            try self.writeLiteral(literal);
        }
        try self.writer.writeAll("]");
    }

    fn writeStringArray(self: *Self, values: []const []const u8) !void {
        try self.writer.writeAll("[");
        for (values, 0..) |value, i| {
            if (i != 0) try self.writer.writeAll(",");
            try std.json.Stringify.value(value, .{}, self.writer);
        }
        try self.writer.writeAll("]");
    }

    fn writeArray(
        self: *Self,
        comptime T: type,
        values: []const T,
        comptime writeValue: fn (*Self, T) anyerror!void,
    ) !void {
        try self.writer.writeAll("[");
        for (values, 0..) |value, i| {
            if (i != 0) try self.writer.writeAll(",");
            try writeValue(self, value);
        }
        try self.writer.writeAll("]");
    }

    fn writeNamedObjectMap(
        self: *Self,
        comptime T: type,
        items: []const Spec.Named(T),
        comptime writeValue: fn (*Self, T) anyerror!void,
    ) !void {
        try self.writer.writeAll("{");
        var first = true;

        const sorted = try self.allocator.dupe(Spec.Named(T), items);
        defer self.allocator.free(sorted);
        sortNamedItems(T, sorted);

        for (sorted) |item| {
            try self.writeFieldName(&first, item.name);
            try writeValue(self, item.value);
        }

        try self.writer.writeAll("}");
    }

    fn writeFieldName(self: *Self, first: *bool, name: []const u8) !void {
        if (!first.*) try self.writer.writeAll(",");
        first.* = false;
        try std.json.Stringify.value(name, .{}, self.writer);
        try self.writer.writeAll(":");
    }

    fn writeStringField(self: *Self, first: *bool, name: []const u8, value: []const u8) !void {
        try self.writeFieldName(first, name);
        try std.json.Stringify.value(value, .{}, self.writer);
    }

    fn writeOptionalStringField(self: *Self, first: *bool, name: []const u8, value: ?[]const u8) !void {
        if (value) |present| {
            try self.writeStringField(first, name, present);
        }
    }

    fn writeOptionalBoolField(self: *Self, first: *bool, name: []const u8, value: bool) !void {
        if (!value) return;
        try self.writeFieldName(first, name);
        try std.json.Stringify.value(value, .{}, self.writer);
    }

    fn writeRawString(self: *Self, value: []const u8) anyerror!void {
        try std.json.Stringify.value(value, .{}, self.writer);
    }
};

fn sortNamedItems(comptime T: type, items: []Spec.Named(T)) void {
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        const item = items[i];
        var j = i;
        while (j > 0 and std.mem.order(u8, items[j - 1].name, item.name) == .gt) : (j -= 1) {
            items[j] = items[j - 1];
        }
        items[j] = item;
    }
}

fn sortScopes(items: []Spec.Scope) void {
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        const item = items[i];
        var j = i;
        while (j > 0 and std.mem.order(u8, items[j - 1].name, item.name) == .gt) : (j -= 1) {
            items[j] = items[j - 1];
        }
        items[j] = item;
    }
}

fn sortSecurityRequirementItems(items: []Spec.SecurityRequirementItem) void {
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        const item = items[i];
        var j = i;
        while (j > 0 and std.mem.order(u8, items[j - 1].name, item.name) == .gt) : (j -= 1) {
            items[j] = items[j - 1];
        }
        items[j] = item;
    }
}
