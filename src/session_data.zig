const std = @import("std");
const protocol = @import("protocol.zig");
const Connection = @import("connection.zig");
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
    /// Arbitrary data from the previous, restarted connection.
    /// The data is sent as the `restart` attribute of the `terminated` event.
    /// The client should leave the data intact.
    terminated_restart_data: ?protocol.Value = null,

    pub fn init(allocator: std.mem.Allocator) SessionData {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
        };
    }

    pub fn deinit(data: *SessionData) void {
        data.string_storage.deinit(data.allocator);
        data.threads.deinit(data.allocator);
        data.modules.deinit(data.allocator);
        data.output.deinit(data.allocator);

        data.arena.deinit();
    }

    pub fn handle_event_output(data: *SessionData, connection: *Connection) !void {
        const event = try connection.get_and_parse_event(protocol.OutputEvent, "output");
        defer event.deinit();
        try data.output.ensureUnusedCapacity(data.allocator, 1);
        const output = try data.clone_anytype(event.value);
        data.output.appendAssumeCapacity(output);

        try connection.event_handled_output(event.value.seq);
    }

    pub fn handle_event_modules(data: *SessionData, connection: *Connection) !void {
        const event = try connection.get_and_parse_event(protocol.ModuleEvent, "module");
        defer event.deinit();
        try data.add_module(event.value.body.module);
        try connection.event_handled_modules(event.value.seq);
    }

    pub fn handle_event_terminated(data: *SessionData, connection: *Connection) !void {
        const event = try connection.get_and_parse_event(protocol.TerminatedEvent, "terminated");
        defer event.deinit();

        if (event.value.body) |body| {
            data.terminated_restart_data = try data.clone_anytype(body.restart);
        }

        try connection.event_handled_terminated(event.value.seq);
    }

    pub fn handle_response_threads(data: *SessionData, connection: *Connection, seq: i32) !void {
        const parsed = try connection.get_parse_validate_response(protocol.ThreadsResponse, seq, "threads");
        defer parsed.deinit();
        const array = parsed.value.body.threads;
        try data.set_threads(array);

        try connection.response_handled_threads(seq);
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

    fn clone_anytype(data: *SessionData, value: anytype) error{OutOfMemory}!@TypeOf(value) {
        const Cloner = struct {
            const Cloner = @This();
            data: *SessionData,
            allocator: std.mem.Allocator,
            pub fn clone_string(cloner: Cloner, string: []const u8) ![]const u8 {
                return try cloner.data.get_or_clone_string(string);
            }
        };

        const cloner = Cloner{
            .data = data,
            .allocator = data.arena.allocator(),
        };
        return try utils.clone_anytype(cloner, value);
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
