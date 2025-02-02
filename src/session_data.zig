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

pub const StackFrames = struct {
    thread_id: i32,
    data: []const protocol.StackFrame,
};

pub const Scopes = struct {
    frame_id: i32,
    data: []const protocol.Scope,
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

pub const Variables = struct {
    reference: i32,
    data: []const protocol.Variable,
};

pub const SourceContent = struct {
    path: ?[]const u8,
    source_reference: ?i32,
    content: []const u8,
    mime_type: ?[]const u8,
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
stack_frames: std.ArrayListUnmanaged(StackFrames) = .{},
scopes: std.ArrayListUnmanaged(Scopes) = .{},
variables: std.ArrayListUnmanaged(Variables) = .{},
threads_state: std.ArrayListUnmanaged(ThreadState) = .{},
breakpoints: std.ArrayListUnmanaged(protocol.Breakpoint) = .{},
sources: std.ArrayListUnmanaged(protocol.Source) = .{},
sources_content: std.ArrayListUnmanaged(SourceContent) = .{},

/// Setting of function breakpoints replaces all existing function breakpoints with new function breakpoints.
/// This is here to allow adding and removing individual breakpoints.
function_breakpoints: std.ArrayListUnmanaged(protocol.FunctionBreakpoint) = .{},

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
    data.variables.deinit(data.allocator);
    data.threads_state.deinit(data.allocator);
    data.function_breakpoints.deinit(data.allocator);
    data.breakpoints.deinit(data.allocator);
    data.sources.deinit(data.allocator);
    data.sources_content.deinit(data.allocator);

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

pub fn set_stack_frames(data: *SessionData, thread_id: i32, response: []const protocol.StackFrame) !void {
    try data.stack_frames.ensureUnusedCapacity(data.allocator, 1);
    if (get_entry_ptr(data.stack_frames.items, "thread_id", thread_id)) |entry| {
        // FIXME: check docs: protocol.StackTraceResponse.body.totalFrames
        entry.data = try data.clone_anytype(response);
    } else {
        data.stack_frames.appendAssumeCapacity(.{
            .thread_id = thread_id,
            .data = try data.clone_anytype(response),
        });
    }

    for (data.stack_frames.items) |item| {
        for (item.data) |frame| {
            if (frame.source) |source| {
                try data.set_source(source);
            }
        }
    }
}

pub fn set_source(data: *SessionData, source: protocol.Source) !void {
    const exists =
        (source.path != null and entry_exists(data.sources.items, "path", source.path)) or
        (source.sourceReference != null and entry_exists(data.sources.items, "sourceReference", source.sourceReference));

    if (!exists) {
        try data.sources.append(data.allocator, try data.clone_anytype(source));
    }
}

pub fn get_source_by_reference(data: *SessionData, reference: i32) ?protocol.Source {
    return (get_entry_ptr(data.sources.items, "sourceReference", reference) orelse return null).*;
}

pub fn get_source_by_path(data: *SessionData, path: []const u8) ?protocol.Source {
    return (get_entry_ptr(data.sources.items, "path", path) orelse return null).*;
}

pub fn set_source_content(data: *SessionData, content: SourceContent) !void {
    if (content.path == null and content.source_reference == null) {
        return error.SourceContentWithNoIdentifier;
    }

    const entry =
        get_entry_ptr(data.sources_content.items, "source_reference", content.source_reference) orelse
        get_entry_ptr(data.sources_content.items, "path", content.path) orelse
        try data.sources_content.addOne(data.allocator);

    entry.* = try data.clone_anytype(content);
}

pub fn set_scopes(data: *SessionData, frame_id: i32, response: []const protocol.Scope) !void {
    try data.scopes.ensureUnusedCapacity(data.allocator, 1);
    if (get_entry_ptr(data.scopes.items, "frame_id", frame_id)) |entry| {
        entry.data = try data.clone_anytype(response);
    } else {
        data.scopes.appendAssumeCapacity(.{
            .frame_id = frame_id,
            .data = try data.clone_anytype(response),
        });
    }
}

pub fn set_variables(data: *SessionData, variables_reference: i32, response: []const protocol.Variable) !void {
    try data.variables.ensureUnusedCapacity(data.allocator, 1);
    if (get_entry_ptr(data.variables.items, "reference", variables_reference)) |entry| {
        entry.data = try data.clone_anytype(response);
    } else {
        data.variables.appendAssumeCapacity(.{
            .reference = variables_reference,
            .data = try data.clone_anytype(response),
        });
    }
}

pub fn add_module(data: *SessionData, module: protocol.Module) !void {
    try data.modules.ensureUnusedCapacity(data.allocator, 1);

    if (!entry_exists(data.modules.items, "id", module.id)) {
        data.modules.appendAssumeCapacity(try data.clone_anytype(module));
    }
}

pub fn set_breakpoints(data: *SessionData, breakpoints: []const protocol.Breakpoint) !void {
    for (breakpoints) |bp| {
        if (entry_exists(data.breakpoints.items, "id", bp.id)) {
            try data.update_breakpoint(bp);
        } else {
            try data.breakpoints.append(data.allocator, try data.clone_anytype(bp));
        }
    }
}

pub fn remove_breakpoint(data: *SessionData, id: ?i32) void {
    const index = get_entry_index(
        data.breakpoints.items,
        "id",
        id orelse return,
    ) orelse return;

    _ = data.breakpoints.orderedRemove(index);
}

fn update_breakpoint(data: *SessionData, breakpoint: protocol.Breakpoint) !void {
    const id = breakpoint.id orelse return error.NoBreakpointIDGiven;
    const entry = get_entry_ptr(data.breakpoints.items, "id", id) orelse return error.BreakpointDoesNotExist;

    entry.* = try data.clone_anytype(breakpoint);
    entry.id = id;
}

pub fn add_function_breakpoint(data: *SessionData, breakpoint: protocol.FunctionBreakpoint) !void {
    if (!entry_exists(data.function_breakpoints.items, "name", breakpoint.name)) {
        try data.function_breakpoints.append(data.allocator, try data.clone_anytype(breakpoint));
    }
}

pub fn remove_function_breakpoint(data: *SessionData, name: []const u8) void {
    const index = get_entry_index(data.function_breakpoints.items, "name", name) orelse return;
    _ = data.function_breakpoints.orderedRemove(index);
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
    const index = get_entry_index(slice, field_name, value) orelse return null;
    return &slice[index];
}

fn get_entry_index(slice: anytype, comptime field_name: []const u8, value: anytype) ?usize {
    if (@typeInfo(@TypeOf(value)) == .optional and value == null) return null;

    const info = @typeInfo(@TypeOf(value));
    const is_slice = info == .pointer and info.pointer.size == .slice;
    for (slice, 0..) |item, i| {
        const field = @field(item, field_name);
        if (is_slice) {
            const unwraped_field = if (@typeInfo(@TypeOf(field)) == .optional)
                field orelse continue
            else
                field;

            if (std.mem.eql(info.pointer.child, unwraped_field, value)) {
                return i;
            }
        } else if (std.meta.eql(field, value)) {
            return i;
        }
    }

    return null;
}
