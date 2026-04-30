const std = @import("std");
const lib = @import("embed_std").std;
const openapi = @import("openapi");
const Spec = openapi.Spec;
const Files = openapi.Files;
const Type = std.builtin.Type;
const NamedProperty = Spec.Named(Spec.SchemaOrRef);
const FlattenMode = enum {
    preserve_required,
    force_optional,
};
const FileSchema = struct {
    file_name: []const u8,
    schema_name: []const u8,
};

const additional_properties_field_name: [:0]const u8 = "additional_properties";

pub fn make(comptime files: Files) blk: {
    @setEvalBranchQuota(200_000);

    const schemas = collectSchemas(files);
    var fields: [schemas.len]Type.StructField = undefined;

    for (schemas, 0..) |file_schema, i| {
        const field_name = zigIdentifier(file_schema.schema_name);
        const model_type = namedSchemaType(files, file_schema.file_name, file_schema.schema_name);
        ensureUniqueSchemaFieldName(fields[0..i], field_name, file_schema.file_name, file_schema.schema_name);

        fields[i] = .{
            .name = field_name,
            .type = type,
            .default_value_ptr = @as(?*const anyopaque, @ptrCast(&model_type)),
            .is_comptime = true,
            .alignment = 1,
        };
    }

    break :blk @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = &fields,
        .decls = &.{},
        .is_tuple = false,
    } });
} {
    return .{};
}

pub fn typeForSchemaOrRef(
    comptime files: Files,
    comptime current_file_name: []const u8,
    comptime schema_or_ref: Spec.SchemaOrRef,
    comptime context_name: []const u8,
) type {
    return lowerSchemaOrRef(files, current_file_name, schema_or_ref, context_name);
}

fn collectSchemas(comptime files: Files) []const FileSchema {
    const total = schemaCount(files);
    comptime var schemas: [total]FileSchema = undefined;
    comptime var index: usize = 0;

    inline for (files.items) |file| {
        const components = file.spec.components orelse continue;
        inline for (components.schemas) |schema| {
            schemas[index] = .{
                .file_name = file.name,
                .schema_name = schema.name,
            };
            index += 1;
        }
    }

    return schemas[0..];
}

fn schemaCount(comptime files: Files) usize {
    comptime var total: usize = 0;

    inline for (files.items) |file| {
        if (file.spec.components) |components| {
            total += components.schemas.len;
        }
    }

    return total;
}

fn ensureUniqueSchemaFieldName(
    comptime existing_fields: []const Type.StructField,
    comptime field_name: [:0]const u8,
    comptime file_name: []const u8,
    comptime schema_name: []const u8,
) void {
    inline for (existing_fields) |existing| {
        if (std.mem.eql(u8, existing.name, field_name)) {
            @compileError(std.fmt.comptimePrint(
                "Duplicate model name '{s}' from schema '{s}' in file '{s}'.",
                .{ field_name, schema_name, file_name },
            ));
        }
    }
}

fn namedSchemaType(comptime files: Files, comptime file_name: []const u8, comptime schema_name: []const u8) type {
    const schema_or_ref = files.findSchema(file_name, schema_name) orelse @compileError(std.fmt.comptimePrint(
        "Schema '{s}' was not found in file '{s}'.",
        .{ schema_name, file_name },
    ));
    return lowerSchemaOrRef(files, file_name, schema_or_ref, schema_name);
}

fn lowerSchemaOrRef(
    comptime files: Files,
    comptime current_file_name: []const u8,
    comptime schema_or_ref: Spec.SchemaOrRef,
    comptime context_name: []const u8,
) type {
    return switch (schema_or_ref) {
        .schema => |schema| lowerSchema(files, current_file_name, schema, context_name),
        .reference => |reference| blk: {
            const resolved = files.resolveSchemaRef(current_file_name, reference.ref_path) orelse @compileError(std.fmt.comptimePrint(
                "Unsupported schema reference '{s}' for '{s}' in file '{s}'.",
                .{ reference.ref_path, context_name, current_file_name },
            ));
            break :blk namedSchemaType(files, resolved.file_name, resolved.schema_name);
        },
    };
}

fn lowerSchema(
    comptime files: Files,
    comptime current_file_name: []const u8,
    comptime schema: Spec.Schema,
    comptime context_name: []const u8,
) type {
    @setEvalBranchQuota(200_000);

    if (schema.one_of.len != 0) return lowerOneOfSchema(files, current_file_name, schema, context_name);
    if (schema.any_of.len != 0) return lowerAnyOfSchema(files, current_file_name, schema, context_name);

    if (schema.all_of.len != 0) return lowerAllOfSchema(files, current_file_name, schema, context_name);
    if (isObjectSchema(schema)) return lowerObjectSchema(files, current_file_name, schema, context_name);

    const schema_type = schema.schema_type orelse @compileError(std.fmt.comptimePrint(
        "Schema '{s}' is missing a supported type.",
        .{context_name},
    ));

    if (std.mem.eql(u8, schema_type, "array")) {
        const items = schema.items orelse @compileError(std.fmt.comptimePrint(
            "Array schema '{s}' is missing items.",
            .{context_name},
        ));
        return []const lowerSchemaOrRef(files, current_file_name, items.*, std.fmt.comptimePrint("{s}Item", .{context_name}));
    }

    if (std.mem.eql(u8, schema_type, "string")) return []const u8;
    if (std.mem.eql(u8, schema_type, "boolean")) return bool;
    if (std.mem.eql(u8, schema_type, "integer")) return integerType(schema.format);
    if (std.mem.eql(u8, schema_type, "number")) return numberType(schema.format);

    @compileError(std.fmt.comptimePrint(
        "Schema '{s}' uses unsupported type '{s}'.",
        .{ context_name, schema_type },
    ));
}

fn lowerOneOfSchema(
    comptime files: Files,
    comptime current_file_name: []const u8,
    comptime schema: Spec.Schema,
    comptime context_name: []const u8,
) type {
    const variant_count = schema.one_of.len;
    if (variant_count == 0) {
        @compileError(std.fmt.comptimePrint(
            "Schema '{s}' declares oneOf without variants.",
            .{context_name},
        ));
    }

    comptime var enum_fields: [variant_count]Type.EnumField = undefined;
    comptime var union_fields: [variant_count]Type.UnionField = undefined;

    inline for (schema.one_of, 0..) |item, i| {
        const normalized_item = normalizeOneOfVariantSchema(schema, item);
        const variant_name = oneOfVariantName(files, current_file_name, schema, normalized_item, context_name, i);
        const variant_type = lowerSchemaOrRef(
            files,
            current_file_name,
            normalized_item,
            std.fmt.comptimePrint("{s}{d}", .{ context_name, i + 1 }),
        );
        ensureUniqueUnionFieldName(union_fields[0..i], variant_name, context_name);

        enum_fields[i] = .{
            .name = variant_name,
            .value = i,
        };
        union_fields[i] = .{
            .name = variant_name,
            .type = variant_type,
            .alignment = if (@sizeOf(variant_type) > 0) @alignOf(variant_type) else 0,
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

fn normalizeOneOfVariantSchema(
    comptime parent_schema: Spec.Schema,
    comptime schema_or_ref: Spec.SchemaOrRef,
) Spec.SchemaOrRef {
    return switch (schema_or_ref) {
        .reference => schema_or_ref,
        .schema => |schema| blk: {
            if (!shouldInheritParentOneOfObjectContext(parent_schema, schema)) break :blk schema_or_ref;
            break :blk .{ .schema = inheritParentOneOfObjectContext(parent_schema, schema) };
        },
    };
}

fn shouldInheritParentOneOfObjectContext(comptime parent_schema: Spec.Schema, comptime schema: Spec.Schema) bool {
    if (parent_schema.properties.len == 0 and parent_schema.schema_type == null) return false;
    if (schema.schema_type != null) return false;
    if (schema.properties.len != 0) return false;
    if (schema.items != null) return false;
    if (schema.all_of.len != 0 or schema.one_of.len != 0 or schema.any_of.len != 0) return false;
    return true;
}

fn inheritParentOneOfObjectContext(comptime parent_schema: Spec.Schema, comptime schema: Spec.Schema) Spec.Schema {
    var merged = schema;
    merged.schema_type = parent_schema.schema_type;
    merged.properties = parent_schema.properties;
    if (merged.additional_properties == null) merged.additional_properties = parent_schema.additional_properties;
    if (merged.discriminator == null) merged.discriminator = parent_schema.discriminator;
    return merged;
}

fn oneOfVariantName(
    comptime files: Files,
    comptime current_file_name: []const u8,
    comptime parent_schema: Spec.Schema,
    comptime schema_or_ref: Spec.SchemaOrRef,
    comptime context_name: []const u8,
    comptime index: usize,
) [:0]const u8 {
    if (parent_schema.discriminator) |discriminator| {
        if (discriminatorVariantName(current_file_name, discriminator, schema_or_ref)) |variant_name| {
            return variant_name;
        }
    }

    return switch (schema_or_ref) {
        .schema => zigIdentifier(std.fmt.comptimePrint("{s}Option{d}", .{ context_name, index + 1 })),
        .reference => |reference| blk: {
            const resolved = files.resolveSchemaRef(current_file_name, reference.ref_path) orelse @compileError(std.fmt.comptimePrint(
                "Unsupported schema reference '{s}' for '{s}' in file '{s}'.",
                .{ reference.ref_path, context_name, current_file_name },
            ));
            break :blk zigIdentifier(resolved.schema_name);
        },
    };
}

fn discriminatorVariantName(
    comptime current_file_name: []const u8,
    comptime discriminator: Spec.Discriminator,
    comptime schema_or_ref: Spec.SchemaOrRef,
) ?[:0]const u8 {
    const target = schemaOrRefDiscriminatorTarget(current_file_name, schema_or_ref) orelse return null;

    inline for (discriminator.mapping) |entry| {
        const mapping_target = Files.parseSchemaRef(current_file_name, entry.value) orelse continue;
        if (std.mem.eql(u8, target.file_name, mapping_target.file_name) and std.mem.eql(u8, target.schema_name, mapping_target.schema_name)) {
            return zigIdentifier(entry.name);
        }
    }

    return null;
}

fn schemaOrRefDiscriminatorTarget(
    comptime current_file_name: []const u8,
    comptime schema_or_ref: Spec.SchemaOrRef,
) ?Files.SchemaRef {
    return switch (schema_or_ref) {
        .reference => |reference| Files.parseSchemaRef(current_file_name, reference.ref_path),
        .schema => |schema| blk: {
            inline for (schema.all_of) |item| {
                if (schemaOrRefDiscriminatorTarget(current_file_name, item)) |target| {
                    break :blk target;
                }
            }
            break :blk null;
        },
    };
}

fn lowerAnyOfSchema(
    comptime files: Files,
    comptime current_file_name: []const u8,
    comptime schema: Spec.Schema,
    comptime context_name: []const u8,
) type {
    const field_count = countFlattenedFields(files, current_file_name, schema, context_name, .preserve_required);
    comptime var fields: [field_count]Type.StructField = undefined;
    comptime var index: usize = 0;

    appendFlattenedFields(files, current_file_name, schema, context_name, .preserve_required, fields[0..], &index);

    return @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = fields[0..index],
        .decls = &.{},
        .is_tuple = false,
    } });
}

fn countAnyOfFields(
    comptime files: Files,
    comptime current_file_name: []const u8,
    comptime schema: Spec.Schema,
    comptime context_name: []const u8,
) usize {
    comptime var total: usize = schema.properties.len;

    inline for (schema.any_of) |item| {
        total += countOptionalBranchFieldsFromSchemaOrRef(files, current_file_name, item, context_name);
    }

    return total;
}

fn countOptionalBranchFieldsFromSchemaOrRef(
    comptime files: Files,
    comptime current_file_name: []const u8,
    comptime schema_or_ref: Spec.SchemaOrRef,
    comptime context_name: []const u8,
) usize {
    return switch (schema_or_ref) {
        .schema => |schema| countOptionalBranchFields(files, current_file_name, schema, context_name),
        .reference => |reference| blk: {
            const resolved = files.resolveSchemaRef(current_file_name, reference.ref_path) orelse @compileError(std.fmt.comptimePrint(
                "Unsupported schema reference '{s}' for '{s}' in file '{s}'.",
                .{ reference.ref_path, context_name, current_file_name },
            ));
            break :blk countOptionalBranchFieldsFromSchemaOrRef(files, resolved.file_name, resolved.schema, resolved.schema_name);
        },
    };
}

fn countOptionalBranchFields(
    comptime files: Files,
    comptime current_file_name: []const u8,
    comptime schema: Spec.Schema,
    comptime context_name: []const u8,
) usize {
    if (schema.additional_properties != null) {
        @compileError(std.fmt.comptimePrint(
            "Schema '{s}' uses additionalProperties inside anyOf, which models.make does not support yet.",
            .{context_name},
        ));
    }

    if (schema.one_of.len != 0) {
        @compileError(std.fmt.comptimePrint(
            "Schema '{s}' uses oneOf inside anyOf, which models.make does not support yet.",
            .{context_name},
        ));
    }

    comptime var total: usize = schema.properties.len;

    inline for (schema.all_of) |item| {
        total += countOptionalBranchFieldsFromSchemaOrRef(files, current_file_name, item, context_name);
    }

    inline for (schema.any_of) |item| {
        total += countOptionalBranchFieldsFromSchemaOrRef(files, current_file_name, item, context_name);
    }

    if (total == 0 and !isObjectSchema(schema)) {
        @compileError(std.fmt.comptimePrint(
            "Schema '{s}' uses anyOf with a non-object branch, which models.make does not support yet.",
            .{context_name},
        ));
    }

    return total;
}

fn appendOptionalBranchFieldsFromSchemaOrRef(
    comptime files: Files,
    comptime current_file_name: []const u8,
    comptime schema_or_ref: Spec.SchemaOrRef,
    comptime context_name: []const u8,
    comptime fields: []Type.StructField,
    comptime index: *usize,
) void {
    switch (schema_or_ref) {
        .schema => |schema| appendOptionalBranchFields(files, current_file_name, schema, context_name, fields, index),
        .reference => |reference| {
            const resolved = files.resolveSchemaRef(current_file_name, reference.ref_path) orelse @compileError(std.fmt.comptimePrint(
                "Unsupported schema reference '{s}' for '{s}' in file '{s}'.",
                .{ reference.ref_path, context_name, current_file_name },
            ));
            switch (resolved.schema) {
                .schema => |schema| appendOptionalBranchFields(files, resolved.file_name, schema, resolved.schema_name, fields, index),
                .reference => |nested| appendOptionalBranchFieldsFromSchemaOrRef(files, resolved.file_name, .{ .reference = nested }, resolved.schema_name, fields, index),
            }
        },
    }
}

fn appendOptionalBranchFields(
    comptime files: Files,
    comptime current_file_name: []const u8,
    comptime schema: Spec.Schema,
    comptime context_name: []const u8,
    comptime fields: []Type.StructField,
    comptime index: *usize,
) void {
    if (schema.additional_properties != null) {
        @compileError(std.fmt.comptimePrint(
            "Schema '{s}' uses additionalProperties inside anyOf, which models.make does not support yet.",
            .{context_name},
        ));
    }

    if (schema.one_of.len != 0) {
        @compileError(std.fmt.comptimePrint(
            "Schema '{s}' uses oneOf inside anyOf, which models.make does not support yet.",
            .{context_name},
        ));
    }

    inline for (schema.all_of) |item| {
        appendOptionalBranchFieldsFromSchemaOrRef(files, current_file_name, item, context_name, fields, index);
    }

    inline for (schema.any_of) |item| {
        appendOptionalBranchFieldsFromSchemaOrRef(files, current_file_name, item, context_name, fields, index);
    }

    inline for (schema.properties) |property| {
        const field_name = zigIdentifier(property.name);
        ensureUniquePropertyFieldName(fields[0..index.*], field_name, context_name, property.name);

        const field_type = optionalPropertyFieldType(files, current_file_name, property);
        fields[index.*] = .{
            .name = field_name,
            .type = field_type,
            .default_value_ptr = &@as(field_type, null),
            .is_comptime = false,
            .alignment = if (@sizeOf(field_type) > 0) @alignOf(field_type) else 0,
        };
        index.* += 1;
    }

    if (schema.properties.len == 0 and schema.all_of.len == 0 and schema.any_of.len == 0 and !isObjectSchema(schema)) {
        @compileError(std.fmt.comptimePrint(
            "Schema '{s}' uses anyOf with a non-object branch, which models.make does not support yet.",
            .{context_name},
        ));
    }
}

fn lowerAllOfSchema(
    comptime files: Files,
    comptime current_file_name: []const u8,
    comptime schema: Spec.Schema,
    comptime context_name: []const u8,
) type {
    const field_count = countFlattenedFields(files, current_file_name, schema, context_name, .preserve_required);
    comptime var fields: [field_count]Type.StructField = undefined;
    comptime var index: usize = 0;

    appendFlattenedFields(files, current_file_name, schema, context_name, .preserve_required, fields[0..], &index);

    return @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = fields[0..index],
        .decls = &.{},
        .is_tuple = false,
    } });
}

fn countFlattenedFields(
    comptime files: Files,
    comptime current_file_name: []const u8,
    comptime schema: Spec.Schema,
    comptime context_name: []const u8,
    comptime mode: FlattenMode,
) usize {
    comptime var total: usize = schema.properties.len + @intFromBool(additionalPropertiesFieldType(files, current_file_name, schema, context_name) != null);

    inline for (schema.all_of) |item| {
        total += countFlattenedFieldsFromSchemaOrRef(files, current_file_name, item, context_name, mode);
    }
    inline for (schema.any_of) |item| {
        total += countFlattenedFieldsFromSchemaOrRef(files, current_file_name, item, context_name, .force_optional);
    }
    inline for (schema.one_of) |item| {
        total += countFlattenedFieldsFromSchemaOrRef(files, current_file_name, item, context_name, .force_optional);
    }

    return total;
}

fn countFlattenedFieldsFromSchemaOrRef(
    comptime files: Files,
    comptime current_file_name: []const u8,
    comptime schema_or_ref: Spec.SchemaOrRef,
    comptime context_name: []const u8,
    comptime mode: FlattenMode,
) usize {
    return switch (schema_or_ref) {
        .schema => |schema| countFlattenedFields(files, current_file_name, schema, context_name, mode),
        .reference => |reference| blk: {
            const resolved = files.resolveSchemaRef(current_file_name, reference.ref_path) orelse @compileError(std.fmt.comptimePrint(
                "Unsupported schema reference '{s}' for '{s}' in file '{s}'.",
                .{ reference.ref_path, context_name, current_file_name },
            ));
            break :blk countFlattenedFieldsFromSchemaOrRef(files, resolved.file_name, resolved.schema, resolved.schema_name, mode);
        },
    };
}

fn appendFlattenedFields(
    comptime files: Files,
    comptime current_file_name: []const u8,
    comptime schema: Spec.Schema,
    comptime context_name: []const u8,
    comptime mode: FlattenMode,
    comptime fields: []Type.StructField,
    comptime index: *usize,
) void {
    inline for (schema.all_of) |item| {
        appendFlattenedFieldsFromSchemaOrRef(files, current_file_name, item, context_name, mode, fields, index);
    }
    inline for (schema.any_of) |item| {
        appendFlattenedFieldsFromSchemaOrRef(files, current_file_name, item, context_name, .force_optional, fields, index);
    }
    inline for (schema.one_of) |item| {
        appendFlattenedFieldsFromSchemaOrRef(files, current_file_name, item, context_name, .force_optional, fields, index);
    }

    inline for (schema.properties) |property| {
        const field_name = zigIdentifier(property.name);
        const field_type = flattenPropertyFieldType(files, current_file_name, property, schema.required, mode);
        appendOrMergePropertyField(fields, index, field_name, field_type, context_name, property.name);
    }

    if (additionalPropertiesFieldType(files, current_file_name, schema, context_name)) |field_type| {
        const merged_type = switch (mode) {
            .preserve_required => field_type,
            .force_optional => optionalizeType(field_type),
        };
        appendOrMergePropertyField(fields, index, additional_properties_field_name, merged_type, context_name, "additionalProperties");
    }

}

fn appendFlattenedFieldsFromSchemaOrRef(
    comptime files: Files,
    comptime current_file_name: []const u8,
    comptime schema_or_ref: Spec.SchemaOrRef,
    comptime context_name: []const u8,
    comptime mode: FlattenMode,
    comptime fields: []Type.StructField,
    comptime index: *usize,
) void {
    switch (schema_or_ref) {
        .schema => |schema| appendFlattenedFields(files, current_file_name, schema, context_name, mode, fields, index),
        .reference => |reference| {
            const resolved = files.resolveSchemaRef(current_file_name, reference.ref_path) orelse @compileError(std.fmt.comptimePrint(
                "Unsupported schema reference '{s}' for '{s}' in file '{s}'.",
                .{ reference.ref_path, context_name, current_file_name },
            ));
            switch (resolved.schema) {
                .schema => |schema| appendFlattenedFields(files, resolved.file_name, schema, resolved.schema_name, mode, fields, index),
                .reference => |nested| appendFlattenedFieldsFromSchemaOrRef(files, resolved.file_name, .{ .reference = nested }, resolved.schema_name, mode, fields, index),
            }
        },
    }
}

fn countAllOfFields(
    comptime files: Files,
    comptime current_file_name: []const u8,
    comptime schema: Spec.Schema,
    comptime context_name: []const u8,
) usize {
    comptime var total: usize = schema.properties.len;

    inline for (schema.all_of) |item| {
        total += countAllOfFieldsFromSchemaOrRef(files, current_file_name, item, context_name);
    }

    return total;
}

fn countAllOfFieldsFromSchemaOrRef(
    comptime files: Files,
    comptime current_file_name: []const u8,
    comptime schema_or_ref: Spec.SchemaOrRef,
    comptime context_name: []const u8,
) usize {
    return switch (schema_or_ref) {
        .schema => |schema| countAllOfFields(files, current_file_name, schema, context_name),
        .reference => |reference| blk: {
            const resolved = files.resolveSchemaRef(current_file_name, reference.ref_path) orelse @compileError(std.fmt.comptimePrint(
                "Unsupported schema reference '{s}' for '{s}' in file '{s}'.",
                .{ reference.ref_path, context_name, current_file_name },
            ));
            break :blk countAllOfFieldsFromSchemaOrRef(files, resolved.file_name, resolved.schema, resolved.schema_name);
        },
    };
}

fn appendAllOfFields(
    comptime files: Files,
    comptime current_file_name: []const u8,
    comptime schema: Spec.Schema,
    comptime context_name: []const u8,
    comptime fields: []Type.StructField,
    comptime index: *usize,
) void {
    if (schema.additional_properties != null) {
        @compileError(std.fmt.comptimePrint(
            "Schema '{s}' uses additionalProperties, which models.make does not support yet.",
            .{context_name},
        ));
    }

    if (schema.one_of.len != 0 or schema.any_of.len != 0) {
        @compileError(std.fmt.comptimePrint(
            "Schema '{s}' uses oneOf/anyOf, which models.make does not support yet.",
            .{context_name},
        ));
    }

    inline for (schema.all_of) |item| {
        appendAllOfFieldsFromSchemaOrRef(files, current_file_name, item, context_name, fields, index);
    }

    inline for (schema.properties) |property| {
        const field_name = zigIdentifier(property.name);
        ensureUniquePropertyFieldName(fields[0..index.*], field_name, context_name, property.name);

        const field_type = propertyFieldType(files, current_file_name, property, schema.required);
        const field_is_optional = isOptionalType(field_type);

        fields[index.*] = .{
            .name = field_name,
            .type = field_type,
            .default_value_ptr = if (field_is_optional) &@as(field_type, null) else null,
            .is_comptime = false,
            .alignment = if (@sizeOf(field_type) > 0) @alignOf(field_type) else 0,
        };
        index.* += 1;
    }

    if (schema.properties.len == 0 and schema.all_of.len == 0 and !isObjectSchema(schema)) {
        @compileError(std.fmt.comptimePrint(
            "Schema '{s}' uses allOf with a non-object branch, which models.make does not support yet.",
            .{context_name},
        ));
    }
}

fn appendAllOfFieldsFromSchemaOrRef(
    comptime files: Files,
    comptime current_file_name: []const u8,
    comptime schema_or_ref: Spec.SchemaOrRef,
    comptime context_name: []const u8,
    comptime fields: []Type.StructField,
    comptime index: *usize,
) void {
    switch (schema_or_ref) {
        .schema => |schema| appendAllOfFields(files, current_file_name, schema, context_name, fields, index),
        .reference => |reference| {
            const resolved = files.resolveSchemaRef(current_file_name, reference.ref_path) orelse @compileError(std.fmt.comptimePrint(
                "Unsupported schema reference '{s}' for '{s}' in file '{s}'.",
                .{ reference.ref_path, context_name, current_file_name },
            ));
            switch (resolved.schema) {
                .schema => |schema| appendAllOfFields(files, resolved.file_name, schema, resolved.schema_name, fields, index),
                .reference => |nested| appendAllOfFieldsFromSchemaOrRef(files, resolved.file_name, .{ .reference = nested }, resolved.schema_name, fields, index),
            }
        },
    }
}

fn lowerObjectSchema(
    comptime files: Files,
    comptime current_file_name: []const u8,
    comptime schema: Spec.Schema,
    comptime context_name: []const u8,
) type {
    const additional_field_type = additionalPropertiesFieldType(files, current_file_name, schema, context_name);
    comptime var fields: [schema.properties.len + @intFromBool(additional_field_type != null)]Type.StructField = undefined;

    inline for (schema.properties, 0..) |property, i| {
        const field_type = propertyFieldType(files, current_file_name, property, schema.required);
        const field_is_optional = isOptionalType(field_type);

        fields[i] = .{
            .name = zigIdentifier(property.name),
            .type = field_type,
            .default_value_ptr = if (field_is_optional) &@as(field_type, null) else null,
            .is_comptime = false,
            .alignment = if (@sizeOf(field_type) > 0) @alignOf(field_type) else 0,
        };
    }

    if (additional_field_type) |field_type| {
        fields[schema.properties.len] = .{
            .name = additional_properties_field_name,
            .type = field_type,
            .default_value_ptr = defaultValuePtr(field_type, .{}),
            .is_comptime = false,
            .alignment = if (@sizeOf(field_type) > 0) @alignOf(field_type) else 0,
        };
    }

    return @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = &fields,
        .decls = &.{},
        .is_tuple = false,
    } });
}

fn ensureUniquePropertyFieldName(
    comptime existing_fields: []const Type.StructField,
    comptime field_name: [:0]const u8,
    comptime schema_name: []const u8,
    comptime property_name: []const u8,
) void {
    inline for (existing_fields) |existing| {
        if (std.mem.eql(u8, existing.name, field_name)) {
            @compileError(std.fmt.comptimePrint(
                "Duplicate property field '{s}' from property '{s}' while lowering schema '{s}'.",
                .{ field_name, property_name, schema_name },
            ));
        }
    }
}

fn appendOrMergePropertyField(
    comptime fields: []Type.StructField,
    comptime index: *usize,
    comptime field_name: [:0]const u8,
    comptime field_type: type,
    comptime schema_name: []const u8,
    comptime property_name: []const u8,
) void {
    if (findStructFieldIndex(fields[0..index.*], field_name)) |existing_index| {
        const merged_type = mergeStructFieldTypes(fields[existing_index].type, field_type, field_name, schema_name, property_name);
        fields[existing_index] = makeStructField(field_name, merged_type);
        return;
    }

    fields[index.*] = makeStructField(field_name, field_type);
    index.* += 1;
}

fn findStructFieldIndex(
    comptime fields: []const Type.StructField,
    comptime field_name: [:0]const u8,
) ?usize {
    inline for (fields, 0..) |field, i| {
        if (std.mem.eql(u8, field.name, field_name)) return i;
    }
    return null;
}

fn mergeStructFieldTypes(
    comptime existing_type: type,
    comptime incoming_type: type,
    comptime field_name: [:0]const u8,
    comptime schema_name: []const u8,
    comptime property_name: []const u8,
) type {
    if (existing_type == incoming_type) return existing_type;

    if (std.mem.eql(u8, field_name, additional_properties_field_name)) {
        return mergeAdditionalPropertiesFieldTypes(existing_type, incoming_type);
    }

    if (isOptionalType(existing_type) and optionalChildType(existing_type) == incoming_type) return existing_type;
    if (isOptionalType(incoming_type) and optionalChildType(incoming_type) == existing_type) return incoming_type;

    @compileError(std.fmt.comptimePrint(
        "Incompatible duplicate property field '{s}' from property '{s}' while lowering schema '{s}'.",
        .{ field_name, property_name, schema_name },
    ));
}

fn makeStructField(comptime field_name: [:0]const u8, comptime field_type: type) Type.StructField {
    return .{
        .name = field_name,
        .type = field_type,
        .default_value_ptr = if (isOptionalType(field_type))
            &@as(field_type, null)
        else if (std.mem.eql(u8, field_name, additional_properties_field_name))
            defaultValuePtr(field_type, .{})
        else
            null,
        .is_comptime = false,
        .alignment = if (@sizeOf(field_type) > 0) @alignOf(field_type) else 0,
    };
}

fn additionalPropertiesFieldType(
    comptime files: Files,
    comptime current_file_name: []const u8,
    comptime schema: Spec.Schema,
    comptime context_name: []const u8,
) ?type {
    if (!isObjectSchema(schema)) return null;

    const value_type = if (schema.additional_properties) |additional_properties|
        switch (additional_properties) {
            .boolean => |enabled| if (enabled) lib.json.Value else return null,
            .schema => |value_schema| lowerSchemaOrRef(
                files,
                current_file_name,
                value_schema.*,
                std.fmt.comptimePrint("{s}AdditionalProperty", .{context_name}),
            ),
        }
    else
        lib.json.Value;

    return AdditionalPropertiesMap(value_type);
}

fn AdditionalPropertiesMap(comptime ValueType: type) type {
    const Inner = lib.json.ArrayHashMap(ValueType);
    return struct {
        storage: Inner = .{},

        pub const additional_properties_value_type = ValueType;

        pub fn deinit(self: *@This(), allocator: lib.mem.Allocator) void {
            self.storage.deinit(allocator);
        }

        pub fn jsonParse(allocator: lib.mem.Allocator, source: anytype, options: lib.json.ParseOptions) !@This() {
            return .{
                .storage = try Inner.jsonParse(allocator, source, options),
            };
        }

        pub fn jsonParseFromValue(allocator: lib.mem.Allocator, source: lib.json.Value, options: lib.json.ParseOptions) !@This() {
            return .{
                .storage = try Inner.jsonParseFromValue(allocator, source, options),
            };
        }

        pub fn jsonStringify(self: @This(), jws: anytype) !void {
            try self.storage.jsonStringify(jws);
        }

        pub fn count(self: @This()) usize {
            return self.storage.map.count();
        }

        pub fn get(self: @This(), key: []const u8) ?ValueType {
            return self.storage.map.get(key);
        }
    };
}

fn isAdditionalPropertiesMapType(comptime T: type) bool {
    return @hasDecl(T, "additional_properties_value_type");
}

fn additionalPropertiesValueType(comptime T: type) type {
    if (!isAdditionalPropertiesMapType(T)) {
        @compileError("additionalPropertiesValueType expects an additional properties map type.");
    }
    return T.additional_properties_value_type;
}

fn mergeAdditionalPropertiesFieldTypes(comptime existing_type: type, comptime incoming_type: type) type {
    const existing_optional = isOptionalType(existing_type);
    const incoming_optional = isOptionalType(incoming_type);
    const existing_base = if (existing_optional) optionalChildType(existing_type) else existing_type;
    const incoming_base = if (incoming_optional) optionalChildType(incoming_type) else incoming_type;

    if (!isAdditionalPropertiesMapType(existing_base) or !isAdditionalPropertiesMapType(incoming_base)) {
        return if (existing_type == incoming_type) existing_type else optionalizeType(lib.json.Value);
    }

    const existing_value = additionalPropertiesValueType(existing_base);
    const incoming_value = additionalPropertiesValueType(incoming_base);
    const merged_value = if (existing_value == incoming_value or existing_value == lib.json.Value)
        existing_value
    else if (incoming_value == lib.json.Value)
        incoming_value
    else
        lib.json.Value;

    const merged_base = AdditionalPropertiesMap(merged_value);
    if (existing_optional or incoming_optional) return optionalizeType(merged_base);
    return merged_base;
}

fn defaultValuePtr(comptime T: type, comptime value: T) *const anyopaque {
    const Holder = struct {
        const stored: T = value;
    };
    return @as(*const anyopaque, @ptrCast(&Holder.stored));
}

fn ensureUniqueUnionFieldName(
    comptime existing_fields: []const Type.UnionField,
    comptime field_name: [:0]const u8,
    comptime schema_name: []const u8,
) void {
    inline for (existing_fields) |existing| {
        if (std.mem.eql(u8, existing.name, field_name)) {
            @compileError(std.fmt.comptimePrint(
                "Duplicate oneOf variant '{s}' while lowering schema '{s}'.",
                .{ field_name, schema_name },
            ));
        }
    }
}

fn propertyFieldType(
    comptime files: Files,
    comptime current_file_name: []const u8,
    comptime property: NamedProperty,
    comptime required: []const []const u8,
) type {
    const base_type = lowerSchemaOrRef(files, current_file_name, property.value, property.name);
    const is_required = isRequired(required, property.name);
    const is_nullable = schemaOrRefNullable(files, current_file_name, property.value);

    if (is_required and !is_nullable) return base_type;
    return ?base_type;
}

fn flattenPropertyFieldType(
    comptime files: Files,
    comptime current_file_name: []const u8,
    comptime property: NamedProperty,
    comptime required: []const []const u8,
    comptime mode: FlattenMode,
) type {
    return switch (mode) {
        .preserve_required => propertyFieldType(files, current_file_name, property, required),
        .force_optional => optionalPropertyFieldType(files, current_file_name, property),
    };
}

fn optionalPropertyFieldType(
    comptime files: Files,
    comptime current_file_name: []const u8,
    comptime property: NamedProperty,
) type {
    return optionalizeType(lowerSchemaOrRef(files, current_file_name, property.value, property.name));
}

fn schemaOrRefNullable(
    comptime files: Files,
    comptime current_file_name: []const u8,
    comptime schema_or_ref: Spec.SchemaOrRef,
) bool {
    return switch (schema_or_ref) {
        .schema => |schema| schema.nullable,
        .reference => |reference| blk: {
            const resolved = files.resolveSchemaRef(current_file_name, reference.ref_path) orelse break :blk false;
            break :blk schemaOrRefNullable(files, resolved.file_name, resolved.schema);
        },
    };
}

fn isObjectSchema(comptime schema: Spec.Schema) bool {
    if (schema.properties.len != 0) return true;
    const schema_type = schema.schema_type orelse return false;
    return std.mem.eql(u8, schema_type, "object");
}

fn integerType(format: ?[]const u8) type {
    const actual = format orelse return i64;
    if (std.mem.eql(u8, actual, "int32")) return i32;
    if (std.mem.eql(u8, actual, "int64")) return i64;
    return i64;
}

fn numberType(format: ?[]const u8) type {
    const actual = format orelse return f64;
    if (std.mem.eql(u8, actual, "float")) return f32;
    if (std.mem.eql(u8, actual, "double")) return f64;
    return f64;
}

fn isRequired(comptime required: []const []const u8, comptime name: []const u8) bool {
    inline for (required) |required_name| {
        if (std.mem.eql(u8, required_name, name)) return true;
    }
    return false;
}

fn isOptionalType(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .optional => true,
        else => false,
    };
}

fn optionalizeType(comptime T: type) type {
    if (isOptionalType(T)) return T;
    return ?T;
}

fn optionalChildType(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .optional => |optional| optional.child,
        else => @compileError("optionalChildType expects an optional type."),
    };
}

fn zigIdentifier(comptime raw: []const u8) [:0]const u8 {
    if (raw.len == 0) return "_";

    comptime var buf: [raw.len + 2:0]u8 = undefined;
    comptime var len: usize = 0;

    if (!isIdentifierStart(raw[0])) {
        buf[len] = '_';
        len += 1;
    }

    inline for (raw) |ch| {
        buf[len] = if (isIdentifierContinue(ch)) ch else '_';
        len += 1;
    }

    if (isKeyword(buf[0..len])) {
        buf[len] = '_';
        len += 1;
    }

    buf[len] = 0;
    return buf[0..len :0];
}

fn isIdentifierStart(ch: u8) bool {
    return ch == '_' or std.ascii.isAlphabetic(ch);
}

fn isIdentifierContinue(ch: u8) bool {
    return ch == '_' or std.ascii.isAlphanumeric(ch);
}

fn isKeyword(comptime name: []const u8) bool {
    const keywords = [_][]const u8{
        "addrspace",
        "align",
        "allowzero",
        "and",
        "anyframe",
        "anytype",
        "asm",
        "async",
        "await",
        "break",
        "callconv",
        "catch",
        "comptime",
        "const",
        "continue",
        "defer",
        "else",
        "enum",
        "errdefer",
        "error",
        "export",
        "extern",
        "fn",
        "for",
        "if",
        "inline",
        "linksection",
        "noalias",
        "noinline",
        "nosuspend",
        "opaque",
        "or",
        "orelse",
        "packed",
        "pub",
        "resume",
        "return",
        "struct",
        "suspend",
        "switch",
        "test",
        "threadlocal",
        "try",
        "union",
        "unreachable",
        "usingnamespace",
        "var",
        "volatile",
        "while",
    };

    inline for (keywords) |keyword| {
        if (std.mem.eql(u8, name, keyword)) return true;
    }
    return false;
}

