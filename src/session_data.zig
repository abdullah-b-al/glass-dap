const std = @import("std");
const protocol = @import("protocol.zig");
const Session = @import("session.zig");
const StringStorageUnmanaged = @import("slice_storage.zig").StringStorageUnmanaged;
const utils = @import("utils.zig");

pub const SessionData = struct {
    allocator: std.mem.Allocator,
    string_storage: StringStorageUnmanaged = .{},
    threads: std.ArrayListUnmanaged(protocol.Thread) = .{},
    modules: std.ArrayListUnmanaged(protocol.Module) = .{},

    pub fn init(allocator: std.mem.Allocator) SessionData {
        return .{ .allocator = allocator };
    }

    pub fn handle_event_modules(data: *SessionData, session: *Session) !void {
        const event = try session.get_and_parse_event(protocol.ModuleEvent, "module");
        defer event.deinit();
        try data.add_module(event.value.body.module);
        try session.event_handled_modules(event.value.seq);
    }

    pub fn handle_response_threads(data: *SessionData, session: *Session, seq: i32) !void {
        const raw_thread, _ = try session.get_response(seq);
        const array = utils.get_value_untyped(raw_thread.value, "body.threads") orelse return;
        const parsed = try std.json.parseFromValue(
            []protocol.Thread,
            session.allocator,
            array,
            .{},
        );
        defer parsed.deinit();
        try data.set_threads(parsed.value);

        try session.response_handled_threads(seq);
    }

    pub fn add_module(data: *SessionData, module: protocol.Module) !void {
        try data.modules.ensureUnusedCapacity(data.allocator, 1);

        if (!entry_exists(data.modules.items, "id", module.id)) {
            data.modules.appendAssumeCapacity(try data.clone_module(module));
        }
    }

    pub fn set_threads(data: *SessionData, threads: []const protocol.Thread) !void {
        data.threads.clearRetainingCapacity();
        try data.threads.ensureUnusedCapacity(data.allocator, threads.len);
        for (threads) |thread| {
            data.threads.appendAssumeCapacity(try data.clone_thread(thread));
        }
    }

    fn clone_module(data: *SessionData, module: protocol.Module) !protocol.Module {
        return protocol.Module{
            .id = try data.clone_value(module.id),
            .name = try data.string_storage.get_and_put(data.allocator, module.name),
            .isOptimized = module.isOptimized,
            .isUserCode = module.isUserCode,
            .path = if (module.path) |v| try data.get_or_clone_string(v) else null,
            .version = if (module.version) |v| try data.get_or_clone_string(v) else null,
            .symbolStatus = if (module.symbolStatus) |v| try data.get_or_clone_string(v) else null,
            .symbolFilePath = if (module.symbolFilePath) |v| try data.get_or_clone_string(v) else null,
            .dateTimeStamp = if (module.dateTimeStamp) |v| try data.get_or_clone_string(v) else null,
            .addressRange = if (module.addressRange) |v| try data.get_or_clone_string(v) else null,
        };
    }

    fn clone_thread(data: *SessionData, thread: protocol.Thread) !protocol.Thread {
        return .{
            .id = thread.id,
            .name = try data.get_or_clone_string(thread.name),
        };
    }

    fn clone_value(data: *SessionData, value: protocol.Value) !protocol.Value {
        return switch (value) {
            .string => |string| .{ .string = try data.get_or_clone_string(string) },
            .number_string => |string| .{ .number_string = try data.get_or_clone_string(string) },
            .object, .array => @panic("TODO"),
            else => value,
        };
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
