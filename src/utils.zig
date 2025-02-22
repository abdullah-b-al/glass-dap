const std = @import("std");
const protocol = @import("protocol.zig");
const SessionData = @import("session_data.zig");
const StringStorage = @import("slice_storage.zig").StringStorage;
const log = std.log.scoped(.utils);
const mem = std.mem;

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

pub fn value_to_object(arena: std.mem.Allocator, value: anytype) !protocol.Object {
    var root = protocol.Object{};
    try value_to_object_recurse(arena, "object", value, &root);
    const maybe_object = root.map.get("object").?;
    switch (maybe_object) {
        .null => return root,
        .object => |object| {
            _ = root.map.swapRemove("object");
            root.deinit(arena);
            return object;
        },
        else => unreachable,
    }
}

/// This function does NOT duplicate memory but it does allocate memory to store slices
fn value_to_object_recurse(arena: std.mem.Allocator, name: []const u8, value: anytype, object: *protocol.Object) error{OutOfMemory}!void {
    const Cloner = struct { allocator: std.mem.Allocator };
    const cloner = Cloner{ .allocator = arena };

    if (@TypeOf(value) == protocol.Object) {
        const cloned = try clone_protocol_object(cloner, value);
        try object.map.put(arena, name, .{ .object = cloned });
        return;
    }

    if (@TypeOf(value) == protocol.Array) {
        const cloned = try clone_protocol_array(cloner, value);
        try object.map.put(arena, name, .{ .array = cloned });
        return;
    }

    switch (@typeInfo(@TypeOf(value))) {
        .bool => {
            try object.map.put(arena, name, .{ .bool = value });
        },
        .int => {
            try object.map.put(arena, name, .{ .integer = @intCast(value) });
        },
        .float => {
            try object.map.put(arena, name, .{ .float = value });
        },

        .null => @compileError("Handle in Optional or provide an empty object"),
        .optional => {
            if (value) |v| {
                try value_to_object_recurse(arena, name, v, object);
            } else {
                try object.map.put(arena, name, .null);
            }
        },
        .@"enum" => {
            try object.map.put(arena, name, .{ .string = @tagName(value) });
        },

        .@"struct" => {
            try object.map.put(arena, name, .{ .object = protocol.Object{} });
            const struct_object = &object.map.getPtr(name).?.object;
            inline for (std.meta.fields(@TypeOf(value))) |field| {
                try value_to_object_recurse(arena, field.name, @field(value, field.name), struct_object);
            }
        },

        .pointer => |pointer| {
            if (pointer.size != .slice) {
                @compileError("Type not supported: " ++ @typeName(@TypeOf(value)));
            }

            if (pointer.child == u8) {
                try object.map.put(arena, name, .{ .string = value });
            } else {
                var list = std.ArrayListUnmanaged(protocol.Value){};
                try list.ensureTotalCapacity(arena, value.len);
                for (value) |v| {
                    const o = try value_to_object(arena, v);
                    list.appendAssumeCapacity(.{ .object = o });
                }
                try object.map.put(arena, name, .{ .array = list });
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
                        try object.map.put(arena, name, .{ .string = @tagName(value) });
                    } else {
                        try value_to_object_recurse(arena, name, v, object);
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

pub fn MemObject(comptime T: type) type {
    return struct {
        pub const utils_MemObject = void;
        pub const ChildType = T;

        const Self = @This();

        arena: *std.heap.ArenaAllocator,
        strings: *StringStorage,
        value: T,

        pub fn deinit(self: *Self) void {
            const allocator = self.arena.child_allocator;

            self.strings.deinit();
            self.arena.deinit();

            allocator.destroy(self.arena);
            allocator.destroy(self.strings);
        }
    };
}

pub fn mem_object_undefined(allocator: std.mem.Allocator, comptime T: type) !MemObject(T) {
    var arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    var strings = try allocator.create(StringStorage);
    errdefer allocator.destroy(strings);
    strings.* = StringStorage.init(allocator);
    errdefer strings.deinit();

    return MemObject(T){
        .arena = arena,
        .strings = strings,
        .value = undefined,
    };
}

pub fn mem_object(allocator: std.mem.Allocator, value: anytype) !MemObject(@TypeOf(value)) {
    var object = try mem_object_undefined(allocator, @TypeOf(value));
    errdefer object.deinit();
    object.value = try mem_object_clone(&object, value);
    return object;
}

pub fn mem_object_clone(mem_object_pointer: anytype, to_clone: anytype) !@TypeOf(to_clone) {
    const info = @typeInfo(@TypeOf(mem_object_pointer));
    if (info != .pointer or info.pointer.is_const) {
        @compileError("MemObject provided isn't a pointer or is a constant pointer.\nProvided: " ++ @typeName(@TypeOf(mem_object_pointer)));
    }

    if (!@hasDecl(info.pointer.child, "utils_MemObject")) {
        @compileError("value provided isn't of the generic type MemObject.");
    }

    const Cloner = struct {
        const Cloner = @This();
        strings: *StringStorage,
        allocator: mem.Allocator,
        pub fn clone_string(cloner: *Cloner, string: []const u8) ![]const u8 {
            return try cloner.strings.get_and_put(string);
        }
    };

    var cloner = Cloner{
        .strings = mem_object_pointer.strings,
        .allocator = mem_object_pointer.arena.allocator(),
    };
    return try clone_anytype(&cloner, to_clone);
}

pub fn oom(_: error{OutOfMemory}) noreturn {
    unreachable;
}

/// Clone is {
///     allocator: std.mem.Allocator
///
///     Optionally: pub fn clone_string(Cloner, string) error{OutOfMemory}![]const u8;
///
/// }
pub fn clone_anytype(cloner: anytype, value: anytype) error{OutOfMemory}!@TypeOf(value) {
    const T = @TypeOf(value);
    const cloner_info = @typeInfo(@TypeOf(cloner));

    // these require special handling
    if (T == protocol.Object) {
        return try clone_protocol_object(cloner, value);
    }

    if (T == protocol.Array) {
        return try clone_protocol_array(cloner, value);
    }

    if (T == []const u8 or T == []u8) {
        const Cloner = switch (cloner_info) {
            .pointer => |info| info.child,
            .@"struct", .@"enum", .@"union" => @TypeOf(cloner),
            else => @compileError("Unsupprted Cloner type"),
        };

        if (@hasDecl(Cloner, "clone_string")) {
            return try cloner.clone_string(value);
        } else {
            return cloner.allocator.dupe(u8, value);
        }
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

pub fn get_field_type(comptime T: type, comptime field_name: []const u8) type {
    for (std.meta.fields(T)) |field| {
        if (std.mem.eql(u8, field.name, field_name)) {
            return field.type;
        }
    }

    var buf: [1024]u8 = undefined;
    const message = std.fmt.bufPrint(&buf, "`{s}` doesn't have field `{s}`", .{ @typeName(T), field_name }) catch unreachable;
    @compileError(message);
}

fn clone_protocol_object(cloner: anytype, object: protocol.Object) !protocol.Object {
    var cloned: protocol.Object = .{};
    var iter = object.map.iterator();
    while (iter.next()) |entry| {
        const key = try clone_anytype(cloner, entry.key_ptr.*);
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

pub fn entry_exists(slice: anytype, comptime field_name: []const u8, value: anytype) bool {
    return get_entry_index(slice, field_name, value) != null;
}

pub fn get_entry_ptr(slice: anytype, comptime field_name: []const u8, value: anytype) ?*@typeInfo(@TypeOf(slice)).pointer.child {
    const index = get_entry_index(slice, field_name, value) orelse return null;
    return &slice[index];
}

pub fn get_entry_index(slice: anytype, comptime field_name: []const u8, value: anytype) ?usize {
    if (@typeInfo(@TypeOf(value)) == .optional and value == null) return null;

    const info = @typeInfo(@TypeOf(value));
    const is_slice = info == .pointer and info.pointer.size == .slice;
    for (slice, 0..) |item, i| {
        const field = @field(item, field_name);
        const unwraped_field = if (@typeInfo(@TypeOf(field)) == .optional)
            field orelse continue
        else
            field;

        if (is_slice) {
            if (std.mem.eql(info.pointer.child, unwraped_field, value)) {
                return i;
            }
        } else if (std.meta.eql(unwraped_field, value)) {
            return i;
        }
    }

    return null;
}

pub fn source_is(source: protocol.Source, path_or_ref: anytype) bool {
    return switch (@TypeOf(path_or_ref)) {
        []const u8 => source.path != null and std.mem.eql(u8, source.path.?, path_or_ref),
        i32 => source.sourceReference != null and source.sourceReference == path_or_ref,
        SessionData.SourceID => switch (path_or_ref) {
            inline else => |v| source_is(source, v),
        },
        else => @compileError("Type must be i32 or []const u8"),
    };
}

pub fn to_protocol_value(allocator: std.mem.Allocator, value: std.json.Value) !protocol.Value {
    return switch (value) {
        .null => .null,
        .bool => |v| .{ .bool = v },
        .integer => |v| .{ .integer = v },
        .float => |v| .{ .float = v },
        .number_string => |v| .{ .number_string = v },
        .string => |v| .{ .string = v },
        .array => |json_array| blk: {
            var array = protocol.Array{};
            try array.ensureTotalCapacity(allocator, json_array.items.len);
            for (json_array.items) |v| {
                array.appendAssumeCapacity(try to_protocol_value(allocator, v));
            }
            break :blk .{ .array = array };
        },
        .object => |json_object| blk: {
            var object = protocol.Object{};
            try object.map.ensureTotalCapacity(allocator, json_object.count());
            var iter = json_object.iterator();
            while (iter.next()) |entry| {
                object.map.putAssumeCapacity(
                    entry.key_ptr.*,
                    try to_protocol_value(allocator, entry.value_ptr.*),
                );
            }

            break :blk .{ .object = object };
        },
    };
}
