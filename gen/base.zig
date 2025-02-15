const std = @import("std");

pub const AdditionalProperties = union(enum) {
    any,
    null,
    allowed_types: []const std.meta.Tag(std.json.Value),
};

pub fn UnionParser(comptime T: type) type {
    return struct {
        pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) std.json.ParseError(@TypeOf(source.*))!T {
            const json_value = try std.json.parseFromTokenSourceLeaky(std.json.Value, allocator, source, options);
            return try jsonParseFromValue(allocator, json_value, options);
        }

        pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) std.json.ParseFromValueError!T {
            inline for (std.meta.fields(T)) |field| {
                const active_field = source == .string and std.mem.eql(u8, source.string, field.name);
                if (field.type == void) {
                    if (active_field) return @unionInit(T, field.name, {});
                } else if (std.json.parseFromValueLeaky(field.type, allocator, source, options)) |result| {
                    return @unionInit(T, field.name, result);
                } else |_| {}
            }
            return error.UnexpectedToken;
        }

        pub fn jsonStringify(self: T, stream: anytype) @TypeOf(stream.*).Error!void {
            switch (self) {
                inline else => |value| {
                    if (@TypeOf(value) != void) {
                        try stream.write(value);
                    }
                },
            }
        }
    };
}

pub fn EnumParser(comptime T: type) type {
    return struct {
        pub fn eql(a: T, b: T) bool {
            const tag_a = std.meta.activeTag(a);
            const tag_b = std.meta.activeTag(b);
            if (tag_a != tag_b) return false;

            return true;
        }

        pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) std.json.ParseError(@TypeOf(source.*))!T {
            const slice = try std.json.parseFromTokenSourceLeaky([]const u8, allocator, source, options);
            return try map_get(slice);
        }

        pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) std.json.ParseFromValueError!T {
            const slice = try std.json.parseFromValueLeaky([]const u8, allocator, source, options);
            return try map_get(slice);
        }

        pub fn jsonStringify(self: T, stream: anytype) @TypeOf(stream.*).Error!void {
            switch (self) {
                else => |val| try stream.write(@tagName(val)),
            }
        }

        fn map_get(slice: []const u8) !T {
            const fields = @typeInfo(T).@"enum".fields;
            inline for (fields) |field| {
                if (std.mem.eql(u8, slice, field.name)) {
                    return @field(T, field.name);
                }
            }

            return error.UnknownField;
        }
    };
}

pub const Object = std.json.ArrayHashMap(Value);
pub const Array = std.ArrayListUnmanaged(Value);

/// Represents any JSON value, potentially containing other JSON values.
/// A .float value may be an approximation of the original value.
/// Arbitrary precision numbers can be represented by .number_string values.
/// See also `std.json.ParseOptions.parse_numbers`.
pub const Value = union(enum) {
    null,
    bool: bool,
    integer: i64,
    float: f64,
    number_string: []const u8,
    string: []const u8,
    array: Array,
    object: Object,

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) std.json.ParseFromValueError!Value {
        switch (source) {
            .null => return @unionInit(Value, "null", {}),
            .string => |string| return @unionInit(Value, "string", string),
            .integer => |integer| return @unionInit(Value, "integer", integer),
            .bool => |b| return @unionInit(Value, "bool", b),
            .float => |float| return @unionInit(Value, "float", float),
            .number_string => |number_string| return @unionInit(Value, "number_string", number_string),
            .object => {
                const result = try std.json.parseFromValueLeaky(Object, allocator, source, options);
                return @unionInit(Value, "object", result);
            },
            .array => {
                const result = try std.json.parseFromValueLeaky(Array, allocator, source, options);
                return @unionInit(Value, "array", result);
            },
        }

        return error.UnexpectedToken;
    }

    pub fn jsonStringify(value: @This(), jws: anytype) !void {
        switch (value) {
            .null => try jws.write(null),
            .bool => |inner| try jws.write(inner),
            .integer => |inner| try jws.write(inner),
            .float => |inner| try jws.write(inner),
            .number_string => |inner| try jws.print("{s}", .{inner}),
            .string => |inner| try jws.write(inner),
            .array => |inner| try jws.write(inner.items),
            .object => |inner| {
                try jws.beginObject();

                var it = inner.map.iterator();
                while (it.next()) |entry| {
                    try jws.objectField(entry.key_ptr.*);
                    try jws.write(entry.value_ptr.*);
                }

                try jws.endObject();
            },
        }
    }
};
