const std = @import("std");
const protocol = @import("protocol.zig");
const log = std.log.scoped(.utils);

pub fn object_inject_merge(allocator: std.mem.Allocator, object: *protocol.Object, ancestors: []const []const u8, extra: protocol.Object) !void {
    if (object.map.count() == 0) return;

    const ancestor = try object_ancestor_get(object, ancestors);
    try object_merge(allocator, ancestor, extra);
}

pub fn object_merge(allocator: std.mem.Allocator, object: *protocol.Object, extra: protocol.Object) !void {
    var iter = extra.map.iterator();
    while (iter.next()) |entry| {
        try object.map.put(allocator, entry.key_ptr.*, entry.value_ptr.*);
    }
}

pub fn object_inject(allocator: std.mem.Allocator, object: *protocol.Object, ancestors: []const []const u8, key: []const u8, value: protocol.Value) !void {
    if (ancestors.len == 0) return;

    var obj = try object_ancestor_get(object, ancestors);
    try obj.map.put(allocator, key, value);
}

pub fn object_ancestor_get(object: *protocol.Object, ancestors: []const []const u8) !*protocol.Object {
    var obj = object;
    for (ancestors) |anc| {
        const maybe_object = object.map.getPtr(anc) orelse return error.AncestorDoesNotExist;
        switch (maybe_object.*) {
            .object => obj = &maybe_object.object,
            else => return error.AncestorIsNotAnObject,
        }
    }

    return obj;
}

pub fn value_to_object(allocator: std.mem.Allocator, value: anytype) !protocol.Object {
    var root = protocol.Object{};
    try value_to_object_recurse(allocator, "object", value, &root);
    const maybe_object = root.map.get("object").?;
    switch (maybe_object) {
        .null => return root,
        .object => |object| {
            _ = root.map.swapRemove("object");
            root.deinit(allocator);
            return object;
        },
        else => unreachable,
    }
}

fn value_to_object_recurse(allocator: std.mem.Allocator, name: []const u8, value: anytype, object: *protocol.Object) error{OutOfMemory}!void {
    if (@TypeOf(value) == protocol.Object) {
        try object.map.put(allocator, name, .{ .object = value });
        return;
    }

    if (@TypeOf(value) == protocol.Array) {
        try object.map.put(allocator, name, .{ .array = value });
        return;
    }

    switch (@typeInfo(@TypeOf(value))) {
        .bool => {
            try object.map.put(allocator, name, .{ .bool = value });
        },
        .int => {
            try object.map.put(allocator, name, .{ .integer = @intCast(value) });
        },
        .float => {
            try object.map.put(allocator, name, .{ .float = value });
        },

        .null => @compileError("Handle in Optional or provide an empty object"),
        .optional => {
            if (value) |v| {
                try value_to_object_recurse(allocator, name, v, object);
            } else {
                try object.map.put(allocator, name, .null);
            }
        },
        .@"enum" => {
            try object.map.put(allocator, name, .{ .string = @tagName(value) });
        },

        .@"struct" => {
            try object.map.put(allocator, name, .{ .object = protocol.Object{} });
            const struct_object = &object.map.getPtr(name).?.object;
            inline for (std.meta.fields(@TypeOf(value))) |field| {
                try value_to_object_recurse(allocator, field.name, @field(value, field.name), struct_object);
            }
        },

        .pointer => |pointer| {
            if (pointer.child == u8 and pointer.size == .slice) {
                try object.map.put(allocator, name, .{ .string = value });
            } else {
                @panic("Type impossible to support: " ++ @typeName(@TypeOf(value)));
            }
        },
        .void => @panic("Handle in Union"),

        .@"union" => |info| {
            if (info.tag_type == null) {
                @panic("Only tagged unions are supported");
            }

            const active = @tagName(std.meta.activeTag(value));
            inline for (info.fields) |f| {
                if (std.mem.eql(u8, f.name, active)) {
                    const v = @field(value, f.name);
                    if (@TypeOf(v) == void) {
                        // treat it as an enum, because that's effectively what it is
                        try object.map.put(allocator, name, .{ .string = @tagName(value) });
                    } else {
                        try value_to_object_recurse(allocator, name, v, object);
                    }
                }
            }
        },

        .array, .enum_literal => @panic("TODO"),

        .type,
        .noreturn,
        .comptime_float,
        .comptime_int,
        .undefined,
        .error_union,
        .error_set,
        .@"fn",
        .@"opaque",
        .frame,
        .@"anyframe",
        .vector,
        => @panic("Type impossible to support: " ++ @typeName((@TypeOf(value)))),
    }
}

pub fn extractInt(string: []const u8) ?[]const u8 {
    var start: ?usize = null;

    inline for (0..10) |num| {
        const needle = std.fmt.digitToChar(num, .lower);
        const index = std.mem.indexOf(u8, string, &.{needle});
        if (index) |i| {
            if (start) |s| start = @min(i, s) else start = i;
        }
    }

    const s = start orelse return null;
    var end = s;
    for (string[s..]) |c| {
        if (std.ascii.isDigit(c)) end += 1 else break;
    }

    return string[s..end];
}

pub fn bit_set_from_struct(source: anytype, comptime Set: type, comptime Kind: type) Set {
    var set: Set = .{};
    inline for (std.meta.fields(@TypeOf(source))) |s_field| {
        @setEvalBranchQuota(10_000);
        inline for (std.meta.fields(Kind), 0..) |t_field, int| {
            if ((s_field.type == ?bool or s_field.type == bool) and std.mem.eql(u8, s_field.name, t_field.name)) {
                const present = @field(source, s_field.name) == true;
                set.setPresent(@enumFromInt(int), present);
            }
        }
    }

    return set;
}

pub fn pull_value(value: ?std.json.Value, comptime wanted: std.meta.Tag(std.json.Value)) ?std.meta.TagPayload(std.json.Value, wanted) {
    const v = value orelse return null;
    return if (v == wanted) @field(value.?, @tagName(wanted)) else null;
}

/// Given a `std.json.Value` traverses the objects to find the wanted value.
/// use a `.` as a separator for path_to_value.
pub fn get_value(value: ?std.json.Value, path_to_value: []const u8, comptime wanted: std.meta.Tag(std.json.Value)) ?std.meta.TagPayload(std.json.Value, wanted) {
    const v = get_value_untyped(value, path_to_value);
    return pull_value(v, wanted);
}

pub fn get_value_untyped(value: ?std.json.Value, path_to_value: []const u8) ?std.json.Value {
    var object = pull_value(value, .object) orelse return null;

    if (std.mem.lastIndexOfScalar(u8, path_to_value, '.')) |index| {
        const value_name = path_to_value[index + 1 ..];

        var iter = std.mem.splitScalar(u8, path_to_value[0..index], '.');
        while (iter.next()) |key| {
            object = pull_value(object.get(key), .object) orelse break;
        }

        if (iter.next() != null) {
            // path_to_value is invalid. One of the middle fields is not an object
            return null;
        }

        return object.get(value_name);
    } else {
        return object.get(path_to_value);
    }
}

pub fn value_is(value: std.json.Value, path_to_value: []const u8, eql_to: std.json.Value) bool {
    const v = get_value_untyped(value, path_to_value) orelse return false;
    if (std.meta.activeTag(v) != std.meta.activeTag(eql_to)) return false;
    return switch (v) {
        .number_string, .string => std.mem.eql(u8, v.string, eql_to.string),
        else => std.meta.eql(v, eql_to),
    };
}

pub fn is_zig_string(comptime T: type) bool {
    switch (@typeInfo(T)) {
        .pointer => |ptr_info| {
            switch (ptr_info.size) {
                .one => switch (@typeInfo(ptr_info.child)) {
                    .array => |info| return info.child == u8,
                    else => |info| {
                        @compileError(@typeName(info.child));
                    },
                },
                .many, .c, .slice => {
                    return ptr_info.child == u8;
                },
            }
        },

        else => return false,
    }
}

/// Clone is {
///     allocator: std.mem.Allocator,
///     pub fn clone_string(Cloner, string) error{OutOfMemory}![]const u8 {}
/// }
pub fn clone_anytype(cloner: anytype, value: anytype) error{OutOfMemory}!@TypeOf(value) {
    const T = @TypeOf(value);

    // these require special handling
    if (T == protocol.Object) {
        return try clone_protocol_object(cloner, value);
    }

    if (T == protocol.Array) {
        return try clone_protocol_array(cloner, value);
    }

    if (T == []const u8 or T == []u8) {
        return try cloner.clone_string(value);
    }

    switch (@typeInfo(T)) {
        .bool, .int, .float, .@"enum" => return value,
        .pointer => |info| {
            if (info.size != .slice) {
                @compileError("Only slices are supported.\nfound: " ++ @tagName(info.size) ++ " " ++ @typeName(T));
            }

            const slice = try cloner.allocator.alloc(info.child, value.len);
            for (slice, value) |*to, from| {
                to.* = try clone_anytype(cloner, from);
            }
            return slice;
        },

        .optional => {
            const unwraped = value orelse return null;
            return try clone_anytype(cloner, unwraped);
        },
        .@"struct" => |struct_info| {
            var v: T = undefined;
            inline for (struct_info.fields) |field| {
                @field(v, field.name) = try clone_anytype(cloner, @field(value, field.name));
            }
            return v;
        },
        .@"union" => {
            var v: T = undefined;
            inline for (std.meta.fields(T)) |field| {
                if (std.mem.eql(u8, field.name, @tagName(std.meta.activeTag(value)))) {
                    if (field.type == void) {
                        v = value;
                    } else {
                        const cloned = try clone_anytype(cloner, @field(value, field.name));
                        v = @unionInit(T, field.name, cloned);
                    }
                }
            }

            return v;
        },

        // zig fmt: off
        .noreturn, .type, .array, .void, .comptime_float, .comptime_int, .undefined,
        .null, .error_union, .error_set, .@"fn", .@"opaque", .frame, .@"anyframe", .vector,
        .enum_literal, => @compileError("Type not possible in a protocol type: " ++ @typeName(T))
        // zig fmt: on
    }
}

pub fn string_to_enum(comptime E: type, string: []const u8) ?E {
    inline for (std.meta.fields(E)) |field| {
        if (std.mem.eql(u8, string, field.name)) {
            return @enumFromInt(field.value);
        }
    }

    return null;
}

fn clone_protocol_object(cloner: anytype, object: protocol.Object) !protocol.Object {
    var cloned: protocol.Object = .{};
    var iter = object.map.iterator();
    while (iter.next()) |entry| {
        const key = try cloner.clone_string(entry.key_ptr.*);
        const value = try clone_anytype(cloner, entry.value_ptr.*);
        try cloned.map.put(cloner.allocator, key, value);
    }

    return cloned;
}

fn clone_protocol_array(cloner: anytype, array: protocol.Array) !protocol.Array {
    var cloned: protocol.Array = .{};
    try cloned.ensureUnusedCapacity(cloner.allocator, array.items.len);
    for (array.items) |entry| {
        const value = try clone_anytype(cloner, entry);
        cloned.appendAssumeCapacity(value);
    }

    return cloned;
}
