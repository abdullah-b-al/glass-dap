const std = @import("std");
const protocol = @import("protocol.zig");

pub fn object_inject(allocator: std.mem.Allocator, object: *protocol.Object, ancestors: []const []const u8, key: []const u8, value: protocol.Value) !void {
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
    const object = root.map.get("object").?.object;
    _ = root.map.swapRemove("object");
    root.deinit(allocator);
    return object;
}

fn value_to_object_recurse(allocator: std.mem.Allocator, name: []const u8, value: anytype, object: *protocol.Object) error{OutOfMemory}!void {
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

        .null => @panic("Handle in Optional"),
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
                @panic("Type impossible to support");
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
    var object = pull_value(value, .object) orelse return null;
    var iter = std.mem.splitScalar(u8, path_to_value, '.');
    while (iter.next()) |key| {
        object = pull_value(object.get(key), .object) orelse break;
    }

    const name_index = std.mem.lastIndexOfScalar(u8, path_to_value, '.') orelse 0;
    const name = if (name_index == 0) path_to_value else path_to_value[name_index + 1 ..];
    return pull_value(object.get(name) orelse return null, wanted);
}
