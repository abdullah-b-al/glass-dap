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

pub const Scopes = struct {
    frame_id: i32,
    data: []const protocol.Scope,
};

pub const Stack = std.ArrayListUnmanaged(protocol.StackFrame);

pub const Thread = struct {
    const State = union(enum) {
        stopped: ?Stopped,
        continued,
        unknown,
    };

    id: i32,
    name: []const u8,
    state: State,
    unlocked: bool,

    stack: Stack,

    pub fn deinit(thread: *Thread, allocator: std.mem.Allocator) void {
        thread.stack.deinit(allocator);
    }
};

pub const Variables = struct {
    reference: i32,
    data: []const protocol.Variable,
};

pub const SourceContentKey = union(enum) {
    path: []const u8,
    reference: i32,
};

const SourceContentHash = struct {
    pub fn hash(_: @This(), key: SourceContentKey) u32 {
        var hasher = std.hash.Wyhash.init(0);
        switch (key) {
            .path => |path| std.hash.autoHashStrat(&hasher, path, .Shallow),
            .reference => |ref| std.hash.autoHashStrat(&hasher, ref, .Shallow),
        }

        return @as(u32, @truncate(hasher.final()));
    }
    pub fn eql(_: @This(), a: SourceContentKey, b: SourceContentKey, _: usize) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .path => std.mem.eql(u8, a.path, b.path),
            .reference => a.reference == b.reference,
        };
    }
};

pub const SourceContent = struct {
    content: []const u8,
    mime_type: ?[]const u8,
};

pub const Stopped = utils.get_field_type(protocol.StoppedEvent, "body");
pub const Continued = utils.get_field_type(protocol.ContinuedEvent, "body");

allocator: std.mem.Allocator,

/// This arena is used to store protocol.Object, protocol.Array and slices that are not a string.
arena: std.heap.ArenaAllocator,

string_storage: StringStorageUnmanaged = .{},
threads: std.AutoArrayHashMapUnmanaged(i32, Thread) = .empty,
modules: std.ArrayListUnmanaged(protocol.Module) = .{},
output: std.ArrayListUnmanaged(protocol.OutputEvent) = .{},
scopes: std.ArrayListUnmanaged(Scopes) = .{},
variables: std.ArrayListUnmanaged(Variables) = .{},
breakpoints: std.ArrayListUnmanaged(protocol.Breakpoint) = .{},
sources: std.ArrayListUnmanaged(protocol.Source) = .{},
sources_content: std.ArrayHashMapUnmanaged(SourceContentKey, SourceContent, SourceContentHash, false) = .empty,

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

    {
        var iter = data.threads.iterator();
        while (iter.next()) |entry| {
            const thread = entry.value_ptr;
            thread.deinit(data.allocator);
        }
    }
    data.threads.deinit(data.allocator);

    data.modules.deinit(data.allocator);
    data.output.deinit(data.allocator);
    data.scopes.deinit(data.allocator);
    data.variables.deinit(data.allocator);
    data.function_breakpoints.deinit(data.allocator);
    data.breakpoints.deinit(data.allocator);
    data.sources.deinit(data.allocator);
    data.sources_content.deinit(data.allocator);

    data.arena.deinit();
}

pub fn set_stopped(data: *SessionData, event: protocol.StoppedEvent) !void {
    const stopped = try data.clone_anytype(event.body);

    if (stopped.threadId) |id| {
        try data.add_or_update_thread(id, null, .{ .stopped = stopped });
    }

    if (stopped.allThreadsStopped orelse false) {
        var iter = data.threads.iterator();
        while (iter.next()) |entry| {
            const thread = entry.value_ptr;
            switch (thread.state) {
                .stopped => {},
                .unknown, .continued => thread.state = .{ .stopped = null },
            }
        }
    }
}

pub fn set_continued(data: *SessionData, event: protocol.ContinuedEvent) !void {
    try data.add_or_update_thread(event.body.threadId, null, .continued);

    if (event.body.allThreadsContinued orelse true) {
        data.set_continued_all();
    }
}

pub fn set_continued_all(data: *SessionData) void {
    var iter = data.threads.iterator();
    while (iter.next()) |entry| {
        const thread = entry.value_ptr;
        switch (thread.state) {
            .continued => {},
            .unknown, .stopped => thread.state = .continued,
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
    // Remove threads that no longer exist
    var iter = data.threads.iterator();
    while (iter.next()) |entry| {
        const old = entry.key_ptr.*;
        if (!utils.entry_exists(threads, "id", old)) {
            _ = data.threads.orderedRemove(old);
            // iterator invalidated reset
            iter = data.threads.iterator();
        }
    }

    for (threads) |new| {
        try data.add_or_update_thread(new.id, new.name, null);
    }
}

fn add_or_update_thread(data: *SessionData, id: i32, name: ?[]const u8, state: ?Thread.State) !void {
    const gop = try data.threads.getOrPut(data.allocator, id);
    if (gop.found_existing) {
        const thread = gop.value_ptr;
        thread.* = .{
            .id = id,
            .name = if (name) |n| try data.clone_anytype(n) else thread.name,
            .state = state orelse thread.state,
            .stack = thread.stack,

            // user controlled
            .unlocked = thread.unlocked,
        };
    } else {
        gop.value_ptr.* = .{
            .id = id,
            .name = try data.clone_anytype(name orelse ""),
            .state = state orelse .unknown,
            .unlocked = !(state == null or state.? == .unknown),
            .stack = Stack{},
        };
    }
}

pub fn set_stack(data: *SessionData, thread_id: i32, clear: bool, response: []const protocol.StackFrame) !void {
    const thread = data.threads.getPtr(thread_id) orelse return;
    if (clear) {
        thread.stack.clearRetainingCapacity();
    }

    try thread.stack.ensureUnusedCapacity(data.allocator, response.len);

    for (response) |frame| {
        thread.stack.appendAssumeCapacity(try data.clone_anytype(frame));
        if (frame.source) |source| {
            try data.set_source(source);
        }
    }
}

pub fn set_source(data: *SessionData, source: protocol.Source) !void {
    const exists = blk: {
        for (data.sources.items) |s| {
            if (source.path) |path| if (utils.source_is(s, path)) break :blk true;
            if (source.sourceReference) |ref| if (utils.source_is(s, ref)) break :blk true;
        }
        break :blk false;
    };

    if (!exists) {
        try data.sources.append(data.allocator, try data.clone_anytype(source));
    }
}

pub fn get_source_by_reference(data: SessionData, reference: i32) ?protocol.Source {
    return (utils.get_entry_ptr(data.sources.items, "sourceReference", reference) orelse return null).*;
}

pub fn get_source_by_path(data: SessionData, path: []const u8) ?protocol.Source {
    return (utils.get_entry_ptr(data.sources.items, "path", path) orelse return null).*;
}

pub fn set_source_content(data: *SessionData, key: SourceContentKey, content: SourceContent) !void {
    const real_key: SourceContentKey = switch (key) {
        .path => |path| .{ .path = try data.string_storage.get_and_put(data.allocator, path) },
        .reference => key,
    };
    const gop = try data.sources_content.getOrPut(data.allocator, real_key);
    gop.value_ptr.* = try data.clone_anytype(content);
}

pub fn set_scopes(data: *SessionData, frame_id: i32, response: []const protocol.Scope) !void {
    try data.scopes.ensureUnusedCapacity(data.allocator, 1);
    if (utils.get_entry_ptr(data.scopes.items, "frame_id", frame_id)) |entry| {
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
    if (utils.get_entry_ptr(data.variables.items, "reference", variables_reference)) |entry| {
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

    if (!utils.entry_exists(data.modules.items, "id", module.id)) {
        data.modules.appendAssumeCapacity(try data.clone_anytype(module));
    }
}

pub fn set_breakpoints(data: *SessionData, breakpoints: []const protocol.Breakpoint) !void {
    for (breakpoints) |bp| {
        if (utils.entry_exists(data.breakpoints.items, "id", bp.id)) {
            try data.update_breakpoint(bp);
        } else {
            try data.breakpoints.append(data.allocator, try data.clone_anytype(bp));
        }
    }
}

pub fn remove_breakpoint(data: *SessionData, id: ?i32) void {
    const index = utils.get_entry_index(
        data.breakpoints.items,
        "id",
        id orelse return,
    ) orelse return;

    _ = data.breakpoints.orderedRemove(index);
}

fn update_breakpoint(data: *SessionData, breakpoint: protocol.Breakpoint) !void {
    const id = breakpoint.id orelse return error.NoBreakpointIDGiven;
    const entry = utils.get_entry_ptr(data.breakpoints.items, "id", id) orelse return error.BreakpointDoesNotExist;

    entry.* = try data.clone_anytype(breakpoint);
    entry.id = id;
}

pub fn add_function_breakpoint(data: *SessionData, breakpoint: protocol.FunctionBreakpoint) !void {
    if (!utils.entry_exists(data.function_breakpoints.items, "name", breakpoint.name)) {
        try data.function_breakpoints.append(data.allocator, try data.clone_anytype(breakpoint));
    }
}

pub fn remove_function_breakpoint(data: *SessionData, name: []const u8) void {
    const index = utils.get_entry_index(data.function_breakpoints.items, "name", name) orelse return;
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
