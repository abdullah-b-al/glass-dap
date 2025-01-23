const std = @import("std");

pub const union_parser_decl = "pub usingnamespace UnionParser(@This());";
pub const enum_parser_decl = "pub usingnamespace EnumParser(@This());";

const Type = struct {
    const Object = struct {
        const Prop = struct {
            required: bool,
            type: Type,
        };
        description: []const u8,
        properties: std.StringArrayHashMap(Prop),
        /// defines allowed types of additional properties.
        /// null means no additional properties are allowed
        additional_properties: union(enum) {
            any,
            null,
            allowed_types: []const std.meta.Tag(std.json.Value),
        },
    };
    const Enum = struct {
        description: []const u8,
        value: []const u8,
    };
    const TypeUnion = union(enum) {
        one_of: []const TypeUnion,
        any: []const []const u8,
        object: Object,
        boolean,
        integer,
        number,
        string,
        enumerate: []const Enum,
        enumerate_any: []const Enum,
        ref: []const u8,
    };
    description: []const u8,
    is_array: bool,
    type: TypeUnion,
};

pub fn main() !void {
    if (std.os.argv.len != 3) {
        std.debug.print("Must provide two arguments: source and destination\n", .{});
        std.process.exit(1);
    }

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var iter = try std.process.argsWithAllocator(arena.allocator());
    _ = iter.skip();
    const path = blk: {
        const p = iter.next().?;
        if (!std.fs.path.isAbsolute(p)) {
            break :blk try std.fs.realpathAlloc(arena.allocator(), p);
        } else {
            break :blk p;
        }
    };
    const destenation = iter.next().?;

    var file = try std.fs.openFileAbsolute(path, .{ .mode = .read_only });
    const content = try file.readToEndAlloc(arena.allocator(), std.math.maxInt(u32));
    file.close();

    const tree = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), content, .{});
    const defs = try parseDefinitions(arena.allocator(), tree.object.get("definitions").?.object);
    var list = std.ArrayList(u8).init(arena.allocator());

    for (defs.keys(), defs.values()) |name, value| {
        const str = try generateType(arena.allocator(), name, value);
        try list.appendSlice(str);
        try list.append('\n');
    }

    const base = @embedFile("base.zig") ++ "\n";
    var f = try std.fs.cwd().createFile(destenation, .{});
    try f.writeAll(base);
    try f.writeAll(list.items);
    f.close();

    _ = std.process.Child.run(.{
        .allocator = arena.allocator(),
        .argv = &.{ "zig", "fmt", destenation },
    }) catch return;
}

////////////////////////////////////////////////////////////////////////////////
// Code generation

fn generateType(allocator: std.mem.Allocator, name: []const u8, t: Type) ![]const u8 {
    var list = std.ArrayList(u8).init(allocator);
    const writer = list.writer();
    try generateTypeWithWriter(allocator, writer, name, t, "pub const", "", ";", '=');

    return try list.toOwnedSlice();
}

/// prefix is pub const
/// suffix is ; or ,
fn generateTypeWithWriter(allocator: std.mem.Allocator, writer: std.ArrayList(u8).Writer, name: []const u8, t: Type, name_prefix: []const u8, type_prefix: []const u8, type_suffix: []const u8, eql_or_colon: u8) !void {
    {
        var iter = std.mem.splitScalar(u8, t.description, '\n');
        while (iter.next()) |line| {
            if (line.len == 0) continue;
            try writer.print("/// {s}\n", .{line});
        }
    }

    if (stringIsKeyword(name)) {
        try writer.print("{s} @\"{s}\"", .{ name_prefix, name });
    } else {
        try writer.print("{s} {s}", .{ name_prefix, name });
    }

    if (t.is_array) {
        try writer.print("{c} {s}[] ", .{ eql_or_colon, type_prefix });
    } else {
        try writer.print("{c} {s} ", .{ eql_or_colon, type_prefix });
    }

    switch (t.type) {
        .object => |object| {
            try writer.print("struct {{", .{});

            if (object.additional_properties != .null) {
                try writer.print("pub const additional_properties: AdditionalProperties = ", .{});
                switch (object.additional_properties) {
                    .null => try writer.print(".null", .{}),
                    .any => try writer.print(".any", .{}),
                    .allowed_types => |array| {
                        try writer.print("&.{{", .{});
                        for (array) |value|
                            try writer.print(".{s},", .{@tagName(value)});

                        try writer.print("}}", .{});
                    },
                }
                try writer.print(";", .{});
            }
            if (object.properties.count() == 0) {
                try writer.print("map: Object", .{});
            }

            for (object.properties.keys(), object.properties.values()) |key, value| {
                if (value.type.description.len > 0)
                    try writer.print("\n", .{});
                const prefix = if (!value.required) "?" else "";
                const suffix = if (!value.required) " = null," else ",";
                try generateTypeWithWriter(allocator, writer, key, value.type, "", prefix, suffix, ':');
            }
            try writer.print("}}", .{});
        },
        .any => {
            try writer.print("Value", .{});
        },
        .ref => |ref| {
            const string = std.mem.trimLeft(u8, ref, "#/definitions/");
            try writer.print("{s}", .{string});
        },
        .one_of => |types| {
            try writer.print("union(enum) {{", .{});
            try writer.print(union_parser_decl ++ "\n", .{});
            for (types, 0..) |item, i| {
                var buf: [32]u8 = undefined;
                try generateTypeWithWriter(
                    allocator,
                    writer,
                    try std.fmt.bufPrint(&buf, "literal_{}", .{i}),
                    .{ .type = item, .description = "", .is_array = false },
                    "",
                    "",
                    ",",
                    ':',
                );
            }
            try writer.print("}}", .{});
        },
        .enumerate_any, .enumerate => |enums| {
            switch (t.type) {
                .enumerate => try writer.print("enum {{\n{s}\n", .{enum_parser_decl}),
                .enumerate_any => try writer.print("union(enum) {{\n{s}\n", .{union_parser_decl}),
                else => unreachable,
            }

            for (enums) |e| {
                var iter = std.mem.splitScalar(u8, e.description, '\n');
                while (iter.next()) |line| {
                    if (line.len == 0) continue;
                    try writer.print("/// {s}\n", .{line});
                }

                // const str = try std.mem.replaceOwned(u8, allocator, e.value, " ", "_");
                if (stringIsKeyword(e.value) or std.mem.count(u8, e.value, " ") > 0) {
                    try writer.print("@\"{s}\", ", .{e.value});
                } else {
                    try writer.print("{s}, ", .{e.value});
                }

                if (e.description.len > 0) {
                    try writer.print("\n", .{});
                }
            }

            if (t.type == .enumerate_any) {
                try writer.print("string: []const u8,", .{});
            }

            try writer.print("}}", .{});
        },

        .integer => {
            try writer.print("i32", .{});
        },
        .number => {
            try writer.print("f32", .{});
        },
        .string => {
            try writer.print("[]const u8", .{});
        },
        .boolean => {
            try writer.print("bool", .{});
        },
    }

    try writer.print("{s}\n", .{type_suffix});
}

fn stringIsKeyword(string: []const u8) bool {
    const zig_keywords: []const []const u8 = &.{ "error", "continue", "enum" };
    for (zig_keywords) |k| if (std.mem.eql(u8, string, k)) return true;
    return false;
}

////////////////////////////////////////////////////////////////////////////////
// Schema parsing

fn parseDefinitions(allocator: std.mem.Allocator, defs: std.json.ObjectMap) !std.StringArrayHashMap(Type) {
    var map = std.StringArrayHashMap(Type).init(allocator);
    var iter = defs.iterator();
    while (iter.next()) |item| {
        const t = try parseType(allocator, item.value_ptr.*, defs, item.key_ptr.*);
        try map.put(item.key_ptr.*, t);
    }

    return map;
}

fn parseType(allocator: std.mem.Allocator, value: std.json.Value, all_definitions: std.json.ObjectMap, current_type_name: []const u8) !Type {
    if (value != .object) {
        std.debug.panic("unknown value [{s}]\n", .{@tagName(value)});
    }

    const description = (value.object.get("description") orelse std.json.Value{ .string = "" }).string;
    const type_value = value.object.get("type") orelse .null;
    const type_is_string = type_value == .string;
    const type_is_array = type_value == .array;

    if (value.object.get("oneOf")) |one_of| {
        var list = std.ArrayList(Type.TypeUnion).init(allocator);
        for (one_of.array.items) |item| {
            switch (item) {
                .object => |object| {
                    var iter = object.iterator();
                    while (iter.next()) |kv| {
                        // for now assume all of it is just $ref
                        try list.append(.{ .ref = kv.value_ptr.*.string });
                    }
                },
                else => @panic("TODO"),
            }
        }
        return Type{
            .description = description,
            .is_array = false,
            .type = .{ .one_of = try list.toOwnedSlice() },
        };
    } else if (value.object.get("allOf")) |allof| {
        var object: Type.Object = .{
            .description = "",
            .properties = std.StringArrayHashMap(Type.Object.Prop).init(allocator),
            .additional_properties = .null,
        };
        for (allof.array.items) |obj| {
            const is_ref = obj.object.get("$ref") != null;
            const type_is_object = blk: {
                const t = obj.object.get("type") orelse break :blk false;
                break :blk std.mem.eql(u8, t.string, "object");
            };

            // make sure all items are objects or references
            if (!is_ref and !type_is_object) {
                unreachable; // not an object
            }

            if (is_ref) {
                const key = std.mem.trimLeft(u8, obj.object.get("$ref").?.string, "#/definitions/");
                const map = if (all_definitions.get(key)) |map| map.object else {
                    std.debug.panic("got null {s} looked up {s}\n", .{ current_type_name, key });
                    unreachable;
                };
                const t = try parseType(allocator, .{ .object = map }, all_definitions, current_type_name);
                try mergeObjectMaps(t.type.object, &object);
            } else {
                const t = try parseType(allocator, obj, all_definitions, current_type_name);
                try mergeObjectMaps(t.type.object, &object);
                object.additional_properties = t.type.object.additional_properties;
            }
        }
        return .{ .description = description, .is_array = false, .type = .{ .object = object } };
        //
    } else if (value.object.get("$ref")) |ref| {
        return Type{
            .description = description,
            .is_array = false,
            .type = .{ .ref = ref.string },
        };
    } else if (type_is_string) {
        const type_str = type_value.string;
        const is_enum = value.object.get("enum") != null;
        const is_any_enum = value.object.get("_enum") != null;

        if (std.mem.eql(u8, type_str, "object")) {
            return .{
                .description = description,
                .is_array = false,
                .type = .{ .object = try parseObject(allocator, value.object, all_definitions, current_type_name) },
            };
        } else if (std.mem.eql(u8, type_str, "string") and (is_enum or is_any_enum)) {
            const array = (value.object.get("enum") orelse value.object.get("_enum").?).array.items;
            const strings = try cloneStringValueArray(allocator, array);

            var enum_descriptions: []const []const u8 = &.{};
            if (value.object.get("enumDescriptions")) |descriptions_array| {
                enum_descriptions = try cloneStringValueArray(allocator, descriptions_array.array.items);
            }
            var list = std.ArrayList(Type.Enum).init(allocator);
            for (strings, 0..) |string, i| {
                try list.append(.{
                    .value = string,
                    .description = if (i < enum_descriptions.len) enum_descriptions[i] else "",
                });
            }

            return Type{
                .description = description,
                .is_array = false,
                .type = if (is_enum)
                    .{ .enumerate = try list.toOwnedSlice() }
                else
                    .{ .enumerate_any = try list.toOwnedSlice() },
            };
        } else if (std.mem.eql(u8, type_str, "string")) {
            return Type{
                .description = description,
                .is_array = false,
                .type = .string,
            };
        } else if (std.mem.eql(u8, type_str, "integer")) {
            return Type{
                .description = description,
                .is_array = false,
                .type = .integer,
            };
        } else if (std.mem.eql(u8, type_str, "number")) {
            return Type{
                .description = description,
                .is_array = false,
                .type = .number,
            };
        } else if (std.mem.eql(u8, type_str, "boolean")) {
            return Type{
                .description = description,
                .is_array = false,
                .type = .boolean,
            };
        } else if (std.mem.eql(u8, type_str, "array")) {
            var t = Type{
                .description = description,
                .is_array = true,
                .type = undefined,
            };
            const items = value.object.get("items").?.object;
            if (items.get("type") != null) {
                t.type = (try parseType(allocator, .{ .object = items }, all_definitions, current_type_name)).type;
            } else if (items.get("$ref")) |ref| {
                t.type = .{ .ref = ref.string };
            } else {
                std.debug.panic("unknown type {s}\n", .{type_str});
            }
            return t;
        } else {
            std.debug.panic("unknown type {s} {s}\n", .{ type_str, current_type_name });
        }
    } else if (type_is_array) {
        for (type_value.array.items) |item|
            std.debug.assert(item == .string);

        const strings = try cloneStringValueArray(allocator, type_value.array.items);
        return Type{
            .description = description,
            .is_array = false,
            .type = .{ .any = strings },
        };
    } else {
        print(value.object);
        std.debug.panic("object with unknown structure\n", .{});
    }

    unreachable;
}

fn parseObject(allocator: std.mem.Allocator, object_map: std.json.ObjectMap, all_definitions: std.json.ObjectMap, current_type_name: []const u8) anyerror!Type.Object {
    var obj: Type.Object = .{
        .description = "",
        .properties = std.StringArrayHashMap(Type.Object.Prop).init(allocator),
        .additional_properties = .null,
    };

    const required: []const []const u8 = blk: {
        if (object_map.get("required")) |req| break :blk try cloneStringValueArray(allocator, req.array.items);
        break :blk &.{};
    };

    if (object_map.get("properties")) |props| {
        var iter = props.object.iterator();
        while (iter.next()) |v| {
            const prop = try parseType(allocator, v.value_ptr.*, all_definitions, current_type_name);
            try obj.properties.put(v.key_ptr.*, .{
                .type = prop,
                .required = isRequired(required, v.key_ptr.*),
            });
        }
    } else {
        // some objects' properties are empty this means that the object is a map to std.json.ObjectMap
    }

    if (object_map.get("additionalProperties")) |add| {
        try getAdditionalProperties(allocator, add, &obj);
    }

    return obj;
}

fn getAdditionalProperties(allocator: std.mem.Allocator, value: std.json.Value, obj: *Type.Object) !void {
    const map = std.StaticStringMap(std.meta.Tag(std.json.Value)).initComptime(.{
        .{ "null", .null },
        .{ "bool", .bool },
        .{ "integer", .integer },
        .{ "float", .float },
        .{ "string", .string },
        .{ "array", .array },
        .{ "object", .object },
    });

    switch (value) {
        .bool => |b| {
            obj.additional_properties = if (b) .any else .null;
        },
        .array => |array| {
            var list = std.ArrayList(std.meta.Tag(std.json.Value)).init(allocator);
            for (array.items) |item| {
                try list.append(map.get(item.string).?);
            }
            obj.additional_properties = .{ .allowed_types = try list.toOwnedSlice() };
        },
        .object => |object| {
            const types = object.get("type").?;
            try getAdditionalProperties(allocator, types, obj);
        },
        .string => |string| {
            var slice = try allocator.alloc(std.meta.Tag(std.json.Value), 1);
            slice[0] = map.get(string).?;
            obj.additional_properties = .{ .allowed_types = slice };
        },
        else => {
            unreachable;
        },
    }
}

// fn parseProperty(allocator: std.mem.Allocator, object: std.json.ObjectMap) !Property {
//     if (object.get("array") != null) {
//         std.debug.assert(object.get("items") != null);
//     }

//     return Property{
//         .type = try parsePropertyType(allocator, object),
//         .is_array = object.get("array") != null and object.get("items") != null,
//         .description = (object.get("description") orelse std.json.Value{ .string = "" }).string,
//     };
// }

// fn parsePropertyType(allocator: std.mem.Allocator, object: std.json.ObjectMap) !Property.Type {
//     const t = object.get("type").?.string;
//     const is_enum = object.get("enum") != null;
//     const is_any_enum = object.get("_enum") != null;

//     if (std.mem.eql(u8, t, "string") and (is_enum or is_any_enum)) {
//         const array = (object.get("enum") orelse object.get("_enum").?).array.items;
//         const strings = try cloneStringValueArray(allocator, array);

//         if (is_enum) {
//             return .{ .enumerate = strings };
//         } else {
//             return .{ .enumerate_any = strings };
//         }
//     } else if (std.mem.eql(u8, t, "string")) {
//         return .string;
//     } else if (std.mem.eql(u8, t, "integer")) {
//         return .integer;
//     } else if (std.mem.eql(u8, t, "boolean")) {
//         return .boolean;
//     } else if (std.mem.eql(u8, t, "array")) {
//         return try parsePropertyType(allocator, object.get("items").?.object);
//     } else {
//         std.debug.panic("unknown type {s}\n", .{t});
//     }
// }

fn cloneStringValueArray(allocator: std.mem.Allocator, array: []std.json.Value) ![]const []const u8 {
    var list = std.ArrayList([]const u8).init(allocator);
    for (array) |item| {
        try list.append(item.string);
    }
    return try list.toOwnedSlice();
}

fn isRequired(array: []const []const u8, property_name: []const u8) bool {
    for (array) |item| {
        if (std.mem.eql(u8, property_name, item)) return true;
    }
    return false;
}

fn has(object: std.json.ObjectMap, key: []const u8) bool {
    return object.get(key) != null;
}

fn print(object: std.json.ObjectMap) void {
    var iter = object.iterator();
    while (iter.next()) |v| {
        switch (v.value_ptr.*) {
            .string => |str| std.debug.print("{s}\n", .{str}),
            .object => |ob| print(ob),
            else => std.debug.print("{}\n", .{v}),
        }
    }
}

fn mergeObjectMaps(from: Type.Object, to: *Type.Object) !void {
    var iter = from.properties.iterator();
    while (iter.next()) |item| {
        try to.properties.put(item.key_ptr.*, item.value_ptr.*);
    }
    to.additional_properties = from.additional_properties;
}
