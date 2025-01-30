const std = @import("std");
const protocol = @import("protocol.zig");
const Connection = @import("connection.zig");
const StringStorageUnmanaged = @import("slice_storage.zig").StringStorageUnmanaged;
const utils = @import("utils.zig");
const log = std.log.scoped(.session_data);

const DebuggeeStatus = union(enum) {
    not_running,
    running,
    stopped,
    exited: i32,
};

const Thread = struct {
    const Stopped = struct {
        description: []const u8 = "",
        text: []const u8 = "",
    };

    data: protocol.Thread,
    state: union(enum) {
        running,
        stopped: Stopped,
    },
};

pub const SessionData = struct {
    allocator: std.mem.Allocator,

    /// This arena is used to store protocol.Object, protocol.Array and slices that are not a string.
    arena: std.heap.ArenaAllocator,

    string_storage: StringStorageUnmanaged = .{},
    threads: std.ArrayListUnmanaged(Thread) = .{},
    modules: std.ArrayListUnmanaged(protocol.Module) = .{},
    output: std.ArrayListUnmanaged(protocol.OutputEvent) = .{},
    stack_frames: std.ArrayListUnmanaged(protocol.StackFrame) = .{},
    status: DebuggeeStatus,

    /// From the protocol:
    /// Arbitrary data from the previous, restarted connection.
    /// The data is sent as the `restart` attribute of the `terminated` event.
    /// The client should leave the data intact.
    terminated_restart_data: ?protocol.Value = null,

    pub fn init(allocator: std.mem.Allocator) SessionData {
        return .{
            .status = .not_running,
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
        };
    }

    pub fn deinit(data: *SessionData) void {
        data.string_storage.deinit(data.allocator);
        data.threads.deinit(data.allocator);
        data.modules.deinit(data.allocator);
        data.output.deinit(data.allocator);
        data.stack_frames.deinit(data.allocator);

        data.arena.deinit();
    }

    pub fn set_stopped(data: *SessionData, event: protocol.StoppedEvent) !void {
        const body = event.body;
        const stopped = Thread.Stopped{
            .description = try data.get_or_clone_string(body.description orelse ""),
            .text = try data.get_or_clone_string(body.text orelse ""),
        };

        const all = body.allThreadsStopped orelse false;
        const id = body.threadId;
        for (data.threads.items) |*thread| {
            if (thread.data.id == id or all) {
                thread.state = .{ .stopped = stopped };
            }
        }
    }

    pub fn set_continued(data: *SessionData, event: protocol.ContinuedEvent) void {
        const all = event.body.allThreadsContinued orelse false;
        const id = event.body.threadId;
        for (data.threads.items) |*item| {
            if (item.data.id == id or all)
                item.state = .running;
        }

        data.status = .running;
    }

    pub fn set_existed(data: *SessionData, event: protocol.ExitedEvent) !void {
        data.status = .{ .exited = event.body.exitCode };
    }

    pub fn set_output(data: *SessionData, event: protocol.OutputEvent) !void {
        try data.output.ensureUnusedCapacity(data.allocator, 1);
        const output = try data.clone_anytype(event);
        data.output.appendAssumeCapacity(output);
    }

    pub fn set_modules(data: *SessionData, event: protocol.ModuleEvent) !void {
        try data.add_module(event.body.module);
    }

    pub fn set_terminated(data: *SessionData, event: protocol.TerminatedEvent) !void {
        if (event.body) |body| {
            data.terminated_restart_data = try data.clone_anytype(body.restart);
        }

        if (data.status != .exited) {
            data.status = .not_running;
        }
    }

    pub fn set_threads(data: *SessionData, threads: []const protocol.Thread) !void {
        data.threads.clearRetainingCapacity();
        try data.threads.ensureUnusedCapacity(data.allocator, threads.len);
        for (threads) |thread| {
            data.threads.appendAssumeCapacity(.{
                .data = try data.clone_anytype(thread),
                .state = if (data.status == .running) .running else .{ .stopped = .{} },
            });
        }
    }

    pub fn set_stack_trace(data: *SessionData, response: protocol.StackTraceResponse) !void {
        const body = response.body;

        try data.stack_frames.ensureUnusedCapacity(data.allocator, body.stackFrames.len);
        for (body.stackFrames) |frame| {
            data.stack_frames.appendAssumeCapacity(try data.clone_anytype(frame));
        }
    }

    pub fn add_module(data: *SessionData, module: protocol.Module) !void {
        try data.modules.ensureUnusedCapacity(data.allocator, 1);

        if (!entry_exists(data.modules.items, "id", module.id)) {
            data.modules.appendAssumeCapacity(try data.clone_anytype(module));
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
