const std = @import("std");
const protocol = @import("protocol.zig");
const Connection = @import("connection.zig");
const StringStorageUnmanaged = @import("slice_storage.zig").StringStorageUnmanaged;
const utils = @import("utils.zig");
const log = std.log.scoped(.session_data);

pub const SessionData = @This();

const DebuggeeStatus = union(enum) {
    not_running,
    running,
    stopped,
    exited: i32,
};

pub const StackFrame = struct {
    thread_id: i32,
    data: protocol.StackFrame,
};

pub const Scope = struct {
    frame_id: i32,
    data: protocol.Scope,
};

pub const Thread = struct {
    id: i32,
    name: []const u8,
    state: ThreadState.State,
};

pub const ThreadID = i32;

pub const ThreadState = struct {
    const State = union(enum) {
        stopped: ?Stopped,
        continued,
    };

    thread_id: ThreadID,
    state: State,
};

pub const Stopped = utils.get_field_type(protocol.StoppedEvent, "body");
pub const Continued = utils.get_field_type(protocol.ContinuedEvent, "body");

allocator: std.mem.Allocator,

/// This arena is used to store protocol.Object, protocol.Array and slices that are not a string.
arena: std.heap.ArenaAllocator,

string_storage: StringStorageUnmanaged = .{},
threads: std.ArrayListUnmanaged(protocol.Thread) = .{},
modules: std.ArrayListUnmanaged(protocol.Module) = .{},
output: std.ArrayListUnmanaged(protocol.OutputEvent) = .{},
stack_frames: std.ArrayListUnmanaged(StackFrame) = .{},
scopes: std.ArrayListUnmanaged(Scope) = .{},
threads_state: std.ArrayListUnmanaged(ThreadState) = .{},
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
    data.scopes.deinit(data.allocator);
    data.stack_frames.deinit(data.allocator);

    data.threads_state.deinit(data.allocator);

    data.arena.deinit();
}

pub fn get_thread_data(data: SessionData, id: i32) ?Thread {
    const thread = get_entry_ptr(data.threads.items, "id", id) orelse return null;
    const state = get_entry_ptr(data.threads_state.items, "thread_id", id) orelse return null;

    return Thread{
        .id = thread.id,
        .name = thread.name,
        .state = state.state,
    };
}

pub fn set_stopped(data: *SessionData, event: protocol.StoppedEvent) !void {
    const stopped = try data.clone_anytype(event.body);

    if (stopped.threadId) |id| {
        if (get_entry_ptr(data.threads_state.items, "thread_id", id)) |entry| {
            entry.* = .{
                .thread_id = entry.thread_id,
                .state = .{ .stopped = stopped },
            };
        } else {
            try data.threads_state.append(data.allocator, .{
                .thread_id = id,
                .state = .{ .stopped = stopped },
            });
        }
    }

    if (stopped.allThreadsStopped orelse false) {
        for (data.threads_state.items) |*item| {
            switch (item.state) {
                .stopped => {},
                .continued => {
                    item.* = .{
                        .thread_id = item.thread_id,
                        .state = .{ .stopped = null },
                    };
                },
            }
        }
    }
}

pub fn set_continued(data: *SessionData, event: protocol.ContinuedEvent) !void {
    if (get_entry_ptr(data.threads_state.items, "thread_id", event.body.threadId)) |entry| {
        entry.* = .{
            .thread_id = entry.thread_id,
            .state = .continued,
        };
    } else {
        try data.threads_state.append(data.allocator, .{
            .thread_id = event.body.threadId,
            .state = .continued,
        });
    }

    for (data.threads_state.items) |*item| {
        switch (item.state) {
            .continued => {},
            .stopped => {
                item.* = .{
                    .thread_id = item.thread_id,
                    .state = .continued,
                };
            },
        }
    }
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
        data.threads.appendAssumeCapacity(try data.clone_anytype(thread));
    }
}

pub fn set_stack_frames(data: *SessionData, thread_id: i32, response: protocol.StackTraceResponse) !void {
    const body = response.body;

    try data.stack_frames.ensureUnusedCapacity(data.allocator, body.stackFrames.len);
    for (body.stackFrames) |frame| {
        data.stack_frames.appendAssumeCapacity(.{
            .thread_id = thread_id,
            .data = try data.clone_anytype(frame),
        });
    }
}

pub fn set_scopes(data: *SessionData, frame_id: i32, response: []const protocol.Scope) !void {
    try data.scopes.ensureUnusedCapacity(data.allocator, response.len);
    for (response) |scope| {
        data.scopes.appendAssumeCapacity(.{
            .frame_id = frame_id,
            .data = try data.clone_anytype(scope),
        });
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
    return get_entry_ptr(slice, field_name, value) != null;
}

fn get_entry_ptr(slice: anytype, comptime field_name: []const u8, value: anytype) ?*@typeInfo(@TypeOf(slice)).pointer.child {
    for (slice) |*item| {
        if (std.meta.eql(@field(item, field_name), value)) {
            return item;
        }
    }

    return null;
}
