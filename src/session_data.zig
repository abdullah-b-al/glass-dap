const std = @import("std");
const protocol = @import("protocol.zig");
const Session = @import("session.zig");
const StringStorageUnmanaged = @import("slice_storage.zig").StringStorageUnmanaged;
const utils = @import("utils.zig");

pub const SessionData = struct {
    allocator: std.mem.Allocator,

    /// This arena is used to store protocol.Object, protocol.Array and slices that are not a string.
    arena: std.heap.ArenaAllocator,

    string_storage: StringStorageUnmanaged = .{},
    threads: std.ArrayListUnmanaged(protocol.Thread) = .{},
    modules: std.ArrayListUnmanaged(protocol.Module) = .{},
    output: std.ArrayListUnmanaged(protocol.OutputEvent) = .{},

    /// From the protocol:
    /// Arbitrary data from the previous, restarted session.
    /// The data is sent as the `restart` attribute of the `terminated` event.
    /// The client should leave the data intact.
    terminated_restart_data: ?protocol.Value = null,

    pub fn init(allocator: std.mem.Allocator) SessionData {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
        };
    }

    pub fn handle_event_output(data: *SessionData, session: *Session) !void {
        const event = try session.get_and_parse_event(protocol.OutputEvent, "output");
        defer event.deinit();
        try data.output.ensureUnusedCapacity(data.allocator, 1);
        const output = try data.clone_anytype(event.value);
        data.output.appendAssumeCapacity(output);

        try session.event_handled_output(event.value.seq);
    }

    pub fn handle_event_modules(data: *SessionData, session: *Session) !void {
        const event = try session.get_and_parse_event(protocol.ModuleEvent, "module");
        defer event.deinit();
        try data.add_module(event.value.body.module);
        try session.event_handled_modules(event.value.seq);
    }

    pub fn handle_event_terminated(data: *SessionData, session: *Session) !void {
        const event = try session.get_and_parse_event(protocol.TerminatedEvent, "terminated");
        defer event.deinit();

        if (event.value.body) |body| {
            data.terminated_restart_data = body.restart;
        }

        try session.event_handled_terminated(event.value.seq);
    }

    pub fn handle_response_threads(data: *SessionData, session: *Session, seq: i32) !void {
        const parsed = try session.get_parse_validate_response(protocol.ThreadsResponse, seq, "threads");
        defer parsed.deinit();
        const array = parsed.value.body.threads;
        try data.set_threads(array);

        try session.response_handled_threads(seq);
    }

    pub fn add_module(data: *SessionData, module: protocol.Module) !void {
        try data.modules.ensureUnusedCapacity(data.allocator, 1);

        if (!entry_exists(data.modules.items, "id", module.id)) {
            data.modules.appendAssumeCapacity(try data.clone_anytype(module));
        }
    }

    pub fn set_threads(data: *SessionData, threads: []const protocol.Thread) !void {
        data.threads.clearRetainingCapacity();
        try data.threads.ensureUnusedCapacity(data.allocator, threads.len);
        for (threads) |thread| {
            data.threads.appendAssumeCapacity(try data.clone_anytype(thread));
        }
    }

    // fn clone_module(data: *SessionData, module: protocol.Module) !protocol.Module {
    //     return protocol.Module{
    //         .id = try data.clone_value(module.id),
    //         .name = try data.string_storage.get_and_put(data.allocator, module.name),
    //         .isOptimized = module.isOptimized,
    //         .isUserCode = module.isUserCode,
    //         .path = if (module.path) |v| try data.get_or_clone_string(v) else null,
    //         .version = if (module.version) |v| try data.get_or_clone_string(v) else null,
    //         .symbolStatus = if (module.symbolStatus) |v| try data.get_or_clone_string(v) else null,
    //         .symbolFilePath = if (module.symbolFilePath) |v| try data.get_or_clone_string(v) else null,
    //         .dateTimeStamp = if (module.dateTimeStamp) |v| try data.get_or_clone_string(v) else null,
    //         .addressRange = if (module.addressRange) |v| try data.get_or_clone_string(v) else null,
    //     };
    // }

    // fn clone_thread(data: *SessionData, thread: protocol.Thread) !protocol.Thread {
    //     return try data.clone_anytype(thread);
    // }

    // fn clone_value(data: *SessionData, value: protocol.Value) !protocol.Value {
    //     return switch (value) {
    //         .string => |string| .{ .string = try data.get_or_clone_string(string) },
    //         .number_string => |string| .{ .number_string = try data.get_or_clone_string(string) },
    //         .object, .array => @panic("TODO"),
    //         else => value,
    //     };
    // }

    fn clone_anytype(data: *SessionData, value: anytype) error{OutOfMemory}!@TypeOf(value) {
        const T = @TypeOf(value);

        // these require special handling
        if (T == protocol.Object) {
            return try data.clone_protocol_object(value);
        }

        if (T == protocol.Array) {
            return try data.clone_protocol_array(value);
        }

        switch (@typeInfo(T)) {
            .bool, .int, .float, .@"enum" => return value,
            .pointer => |info| {
                if (info.size != .slice) {
                    @compileError("Only slices are supported.\nfound: " ++ @tagName(info.size) ++ " " ++ @typeName(T));
                }

                if (T == []const u8) {
                    return try data.get_or_clone_string(value);
                } else {
                    const slice = try data.arena.allocator().alloc(info.child, value.len);
                    for (slice, value) |*to, from| {
                        to.* = try data.clone_anytype(from);
                    }
                    return slice;
                }
            },

            .optional => {
                const unwraped = value orelse return null;
                return try data.clone_anytype(unwraped);
            },
            .@"struct" => |struct_info| {
                var v: T = undefined;
                inline for (struct_info.fields) |field| {
                    @field(v, field.name) = try data.clone_anytype(@field(value, field.name));
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
                            const cloned = try data.clone_anytype(@field(value, field.name));
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

    fn clone_protocol_object(data: *SessionData, object: protocol.Object) !protocol.Object {
        var cloned: protocol.Object = .{};
        var iter = object.map.iterator();
        while (iter.next()) |entry| {
            const key = try data.get_or_clone_string(entry.key_ptr.*);
            const value = try data.clone_anytype(entry.value_ptr.*);
            try cloned.map.put(data.arena.allocator(), key, value);
        }

        return cloned;
    }

    fn clone_protocol_array(data: *SessionData, array: protocol.Array) !protocol.Array {
        var cloned: protocol.Array = .{};
        try cloned.ensureUnusedCapacity(data.arena.allocator(), array.items.len);
        for (array.items) |entry| {
            const value = try data.clone_anytype(entry);
            cloned.appendAssumeCapacity(value);
        }

        return cloned;
    }

    fn get_or_clone_string(data: *SessionData, string: []const u8) ![]const u8 {
        return try data.string_storage.get_and_put(data.allocator, string);
    }

    fn entry_exists(slice: anytype, comptime field_name: []const u8, value: anytype) bool {
        for (slice) |item| {
            if (std.meta.eql(@field(item, field_name), value)) {
                return true;
            }
        }

        return false;
    }
};
