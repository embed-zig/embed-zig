//! Shared comptime helpers for std-compat tests.

const std = @import("std");

fn eqlComptime(comptime a: []const u8, comptime b: []const u8) bool {
    if (a.len != b.len) return false;
    inline for (a, 0..) |byte, i| {
        if (byte != b[i]) return false;
    }
    return true;
}

fn hasStructField(comptime fields: anytype, comptime name: []const u8) bool {
    inline for (fields) |field| {
        if (eqlComptime(field.name, name)) return true;
    }
    return false;
}

fn fieldType(comptime fields: anytype, comptime name: []const u8) type {
    inline for (fields) |field| {
        if (eqlComptime(field.name, name)) return field.type;
    }
    @compileError("missing struct field " ++ name);
}

pub fn assertCompatibleStruct(comptime Actual: type, comptime StdType: type) void {
    const actual_info = @typeInfo(Actual);
    const std_info = @typeInfo(StdType);
    if (actual_info != .@"struct" or std_info != .@"struct")
        @compileError("expected struct types");

    const actual_fields = actual_info.@"struct".fields;
    const std_fields = std_info.@"struct".fields;
    inline for (actual_fields) |actual_field| {
        if (hasStructField(std_fields, actual_field.name) and
            actual_field.type != fieldType(std_fields, actual_field.name))
            @compileError("std_compat mismatch: field type differs for " ++ actual_field.name);
    }
}

pub fn assertCompatibleErrorSet(comptime Actual: type, comptime StdType: type) void {
    const actual_info = @typeInfo(Actual);
    const std_info = @typeInfo(StdType);
    if (actual_info != .error_set or std_info != .error_set)
        @compileError("expected error set types");
}

fn declPath(comptime parent: []const u8, comptime name: []const u8) []const u8 {
    return if (parent.len == 0) name else parent ++ "." ++ name;
}

fn isComparableValueType(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .bool, .int, .float, .comptime_int, .comptime_float, .@"enum" => true,
        else => false,
    };
}

fn assertCompatibleType(comptime ActualType: type, comptime StdType: type, comptime path: []const u8) void {
    if (ActualType == StdType) return;

    const actual_info = @typeInfo(ActualType);
    const std_info = @typeInfo(StdType);
    if (std.meta.activeTag(actual_info) != std.meta.activeTag(std_info))
        @compileError("std_compat mismatch: type kind differs for " ++ path);

    switch (actual_info) {
        .error_set => assertCompatibleErrorSet(ActualType, StdType),
        .@"struct" => {
            assertCompatibleStructAtPath(ActualType, StdType, path);
            assertCompatibleNamespaceAtPath(ActualType, StdType, path);
        },
        else => @compileError("std_compat mismatch: type differs for " ++ path),
    }
}

fn assertCompatibleStructAtPath(comptime Actual: type, comptime StdType: type, comptime path: []const u8) void {
    const actual_info = @typeInfo(Actual);
    const std_info = @typeInfo(StdType);
    if (actual_info != .@"struct" or std_info != .@"struct")
        @compileError("expected struct types");

    const actual_fields = actual_info.@"struct".fields;
    const std_fields = std_info.@"struct".fields;
    inline for (actual_fields) |actual_field| {
        if (hasStructField(std_fields, actual_field.name) and
            actual_field.type != fieldType(std_fields, actual_field.name))
            @compileError("std_compat mismatch: field type differs for " ++ declPath(path, actual_field.name));
    }
}

fn assertCompatibleDecl(comptime ActualContainer: type, comptime StdContainer: type, comptime name: []const u8, comptime parent_path: []const u8) void {
    const path = declPath(parent_path, name);
    if (!@hasDecl(StdContainer, name)) return;

    const actual_decl = @field(ActualContainer, name);
    const std_decl = @field(StdContainer, name);
    if (@TypeOf(actual_decl) != @TypeOf(std_decl))
        @compileError("std_compat mismatch: decl type differs for " ++ path);

    if (@TypeOf(actual_decl) == type) {
        assertCompatibleType(actual_decl, std_decl, path);
        return;
    }

    if (isComparableValueType(@TypeOf(actual_decl)) and actual_decl != std_decl)
        @compileError("std_compat mismatch: decl value differs for " ++ path);
}

fn assertCompatibleNamespaceAtPath(comptime ActualContainer: type, comptime StdContainer: type, comptime parent_path: []const u8) void {
    inline for (std.meta.declarations(ActualContainer)) |decl| {
        assertCompatibleDecl(ActualContainer, StdContainer, decl.name, parent_path);
    }
}

pub fn assertCompatibleNamespace(comptime ActualContainer: type, comptime StdContainer: type) void {
    assertCompatibleNamespaceAtPath(ActualContainer, StdContainer, "std");
}
