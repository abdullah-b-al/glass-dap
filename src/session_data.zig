const std = @import("std");
const protocol = @import("protocol.zig");
const Connection = @import("connection.zig");
const StringStorageUnmanaged = @import("slice_storage.zig").StringStorageUnmanaged;
const utils = @import("utils.zig");
const log = std.log.scoped(.session_data);
const mem = std.mem;
const MemObject = utils.MemObject;

pub const SessionData = @This();

const DebuggeeStatus = union(enum) {
    not_running,
    running,
    stopped,
    exited: i32,
};

pub const ID = i32;
pub const ThreadID = enum(ID) { _ };
pub const FrameID = enum(ID) { _ };
pub const ScopeID = enum(ID) { _ };
pub const VariableReference = enum(ID) { _ };

pub const Threads = std.AutoArrayHashMapUnmanaged(ThreadID, Thread);
pub const Thread = struct {
    const State = union(enum) {
        stopped: ?MemObject(Stopped),
        continued,
        unknown,

        pub fn deinit(self: *@This()) void {
            switch (self.*) {
                .stopped => |stopped| if (stopped) |_| self.stopped.?.deinit(),
                else => {},
            }
        }
    };

    id: ThreadID,
    name: []const u8,
    state: State,
    unlocked: bool,

    stack: std.ArrayListUnmanaged(MemObject(protocol.StackFrame)) = .empty,
    scopes: std.AutoArrayHashMapUnmanaged(FrameID, MemObject([]protocol.Scope)) = .empty,
    variables: std.AutoArrayHashMapUnmanaged(VariableReference, MemObject([]protocol.Variable)) = .empty,

    pub fn deinit(thread: *Thread, allocator: mem.Allocator) void {
        const table = .{
            thread.stack.items,
            thread.scopes.values(),
            thread.variables.values(),
        };
        inline for (table) |entry| {
            for (entry) |*mo| {
                mo.deinit();
            }
        }

        thread.stack.deinit(allocator);
        thread.scopes.deinit(allocator);
        thread.variables.deinit(allocator);
        thread.state.deinit();
    }
};

pub const SourceID = union(enum) {
    path: []const u8,
    reference: i32,

    pub fn eql(a: SourceID, b: SourceID) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .path => mem.eql(u8, a.path, b.path),
            .reference => a.reference == b.reference,
        };
    }

    pub fn from_source(source: protocol.Source) ?SourceID {
        return if (source.sourceReference) |ref|
            .{ .reference = ref }
        else if (source.path) |path|
            .{ .path = path }
        else
            null;
    }
};

pub const SourceIDHash = union(enum) {
    pub fn hash(_: @This(), key: SourceID) u32 {
        var hasher = std.hash.Wyhash.init(0);
        switch (key) {
            .path => |path| std.hash.autoHashStrat(&hasher, path, .Shallow),
            .reference => |ref| std.hash.autoHashStrat(&hasher, ref, .Shallow),
        }

        return @as(u32, @truncate(hasher.final()));
    }

    pub fn eql(_: @This(), a: SourceID, b: SourceID, _: usize) bool {
        return a.eql(b);
    }
};

pub const ModuleID = utils.get_field_type(protocol.Module, "id");
pub const ModuleHash = union(enum) {
    pub fn hash(_: @This(), key: ModuleID) u32 {
        var hasher = std.hash.Wyhash.init(0);
        switch (key) {
            .integer => |integer| std.hash.autoHashStrat(&hasher, integer, .Shallow),
            .string => |string| std.hash.autoHashStrat(&hasher, string, .Shallow),
        }

        return @as(u32, @truncate(hasher.final()));
    }

    pub fn eql(_: @This(), a: ModuleID, b: ModuleID, _: usize) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .integer => a.integer == b.integer,
            .string => mem.eql(u8, a.string, b.string),
        };
    }
};

pub const SourceContent = struct {
    content: []const u8,
    mime_type: ?[]const u8,
};

pub const BreakpointOrigin = union(enum) {
    event,
    source: SourceID,
    function,
};

pub const Breakpoint = struct {
    origin: BreakpointOrigin,
    breakpoint: protocol.Breakpoint,
};

pub const SourceBreakpoints = std.AutoArrayHashMapUnmanaged(i32, protocol.SourceBreakpoint);

pub const Stopped = utils.get_field_type(protocol.StoppedEvent, "body");
pub const Continued = utils.get_field_type(protocol.ContinuedEvent, "body");

allocator: mem.Allocator,

/// This arena is used to store protocol.Object, protocol.Array and slices that are not a string.
arena: std.heap.ArenaAllocator,

string_storage: StringStorageUnmanaged = .empty,
threads: Threads = .empty,
modules: std.ArrayHashMapUnmanaged(ModuleID, MemObject(protocol.Module), ModuleHash, false) = .empty,
breakpoints: std.ArrayListUnmanaged(MemObject(Breakpoint)) = .empty,
sources: std.ArrayHashMapUnmanaged(SourceID, MemObject(protocol.Source), SourceIDHash, false) = .empty,
sources_content: std.ArrayHashMapUnmanaged(SourceID, SourceContent, SourceIDHash, false) = .empty,

output: std.ArrayListUnmanaged(protocol.OutputEvent) = .empty,

/// Setting of function breakpoints replaces all existing function breakpoints with new function breakpoints.
/// These are here to allow adding and removing individual breakpoints.
function_breakpoints: std.ArrayListUnmanaged(protocol.FunctionBreakpoint) = .empty,
source_breakpoints: std.ArrayHashMapUnmanaged(SourceID, SourceBreakpoints, SourceIDHash, false) = .empty,

status: DebuggeeStatus,

/// From the protocol:
/// Arbitrary data from the previous, restarted connection.
/// The data is sent as the `restart` attribute of the `terminated` event.
/// The client should leave the data intact.
terminated_restart_data: ?protocol.Value = null,

pub fn init(allocator: mem.Allocator) SessionData {
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

    data.output.deinit(data.allocator);

    for (data.sources_content.values()) |content| {
        // content.mime_type is interned
        data.allocator.free(content.content);
    }

    data.sources_content.deinit(data.allocator);

    data.function_breakpoints.deinit(data.allocator);

    for (data.source_breakpoints.values()) |*list| {
        list.deinit(data.allocator);
    }
    data.source_breakpoints.deinit(data.allocator);

    const mem_objects = .{
        data.modules.values(),
        data.breakpoints.items,
        data.sources.values(),
    };
    inline for (mem_objects) |slice| {
        for (slice) |*mo| {
            mo.deinit();
        }
    }

    data.modules.deinit(data.allocator);
    data.breakpoints.deinit(data.allocator);
    data.sources.deinit(data.allocator);

    data.arena.deinit();
}

pub fn set_stopped(data: *SessionData, event: protocol.StoppedEvent) !void {
    const stopped = try utils.mem_object(data.allocator, event.body);

    if (stopped.value.threadId) |id| {
        try data.add_or_update_thread(@enumFromInt(id), null, .{ .stopped = stopped });
    }

    if (stopped.value.allThreadsStopped orelse false) {
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
    try data.add_or_update_thread(@enumFromInt(event.body.threadId), null, .continued);

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
            .stopped => {
                thread.state.deinit();
                thread.state = .continued;
            },
            .unknown => thread.state = .continued,
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

pub fn set_module(data: *SessionData, module: protocol.Module) !void {
    try data.modules.ensureUnusedCapacity(data.allocator, 1);
    const mo = try utils.mem_object(data.allocator, module);

    const gop = data.modules.getOrPut(data.allocator, module.id) catch |err| utils.oom(err);

    if (gop.found_existing) {
        gop.value_ptr.deinit();
    }

    gop.key_ptr.* = mo.value.id;
    gop.value_ptr.* = mo;
}

pub fn remove_module(data: *SessionData, module: protocol.Module) void {
    if (data.modules.getPtr(module.id)) |ptr| {
        ptr.deinit();
    }
    _ = data.modules.orderedRemove(module.id);
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
        if (!utils.entry_exists(threads, "id", @as(ID, @intFromEnum(old)))) {
            _ = data.threads.orderedRemove(old);
            // iterator invalidated reset
            iter = data.threads.iterator();
        }
    }

    for (threads) |new| {
        try data.add_or_update_thread(@enumFromInt(new.id), new.name, null);
    }
}

fn add_or_update_thread(data: *SessionData, id: ThreadID, name: ?[]const u8, cloned_state: ?Thread.State) !void {
    const gop = try data.threads.getOrPut(data.allocator, id);
    if (gop.found_existing) {
        const thread = gop.value_ptr;
        if (cloned_state) |new_state| {
            thread.state.deinit();
            thread.state = new_state;
        }

        thread.* = .{
            .id = id,
            .name = if (name) |n| try data.intern_string(n) else thread.name,
            .state = thread.state,
            .stack = thread.stack,

            // user controlled
            .unlocked = thread.unlocked,
        };
    } else {
        gop.value_ptr.* = .{
            .id = id,
            .name = try data.intern_string(name orelse ""),
            .state = cloned_state orelse .unknown,
            .unlocked = !(cloned_state == null or cloned_state.? == .unknown),
            .stack = .empty,
        };
    }
}

pub fn set_stack(data: *SessionData, thread_id: ThreadID, clear: bool, response: []const protocol.StackFrame) !void {
    const thread = data.threads.getPtr(thread_id) orelse return;

    if (clear) {
        for (thread.stack.items) |*mo| {
            mo.deinit();
        }
        thread.stack.clearRetainingCapacity();
    }

    try thread.stack.ensureUnusedCapacity(data.allocator, response.len);

    for (response) |frame| {
        thread.stack.appendAssumeCapacity(try utils.mem_object(data.allocator, frame));
        if (frame.source) |source| {
            try data.set_source(source);
        }
    }
}

pub fn set_source(data: *SessionData, source: protocol.Source) !void {
    const id = try data.intern_source_id(
        SourceID.from_source(source) orelse return error.SourceWithoutID,
    );

    try data.sources.ensureUnusedCapacity(data.allocator, 1);
    var cloned = try utils.mem_object(data.allocator, source);
    errdefer cloned.deinit();
    const gop = data.sources.getOrPutAssumeCapacity(id);
    if (gop.found_existing) {
        gop.value_ptr.deinit();
    }
    gop.value_ptr.* = cloned;
}

pub fn get_source(data: SessionData, source_id: SourceID) ?protocol.Source {
    const maybe = switch (source_id) {
        .path => |path| data.sources.get(.{ .path = path }),
        .reference => |ref| data.sources.get(.{ .reference = ref }),
    };

    return (maybe orelse return null).value;
}

pub fn set_source_content(data: *SessionData, not_owned_key: SourceID, content: SourceContent) !void {
    try data.sources_content.ensureUnusedCapacity(data.allocator, 1);
    const key = try data.intern_source_id(not_owned_key);

    const mime_type = if (content.mime_type) |mt| try data.intern_string(mt) else null;
    const content_string = try data.allocator.dupe(u8, content.content);

    const gop = data.sources_content.getOrPutAssumeCapacity(key);

    if (gop.found_existing) {
        data.allocator.free(gop.value_ptr.content);
    }
    gop.value_ptr.* = .{
        .mime_type = mime_type,
        .content = content_string,
    };
}

pub fn set_scopes(data: *SessionData, thread_id: ThreadID, frame_id: FrameID, response: []protocol.Scope) !void {
    const thread = data.threads.getPtr(thread_id) orelse return;
    try thread.scopes.ensureUnusedCapacity(data.allocator, 1);
    const mo = try utils.mem_object(data.allocator, response);
    const gop = thread.scopes.getOrPutAssumeCapacity(frame_id);
    if (gop.found_existing) {
        gop.value_ptr.deinit();
    }
    gop.value_ptr.* = mo;
}

pub fn set_variables(data: *SessionData, thread_id: ThreadID, variables_reference: VariableReference, response: []protocol.Variable) !void {
    const thread = data.threads.getPtr(thread_id) orelse return;
    try thread.variables.ensureUnusedCapacity(data.allocator, 1);
    const cloned = try utils.mem_object(data.allocator, response);
    const gop = thread.variables.getOrPutAssumeCapacity(variables_reference);
    if (gop.found_existing) {
        gop.value_ptr.deinit();
    }

    gop.value_ptr.* = cloned;
}

pub fn set_breakpoints(data: *SessionData, origin: BreakpointOrigin, breakpoints: []const protocol.Breakpoint) !void {
    if (origin != .event) {
        data.clear_breakpoints(origin);
    }

    if (origin == .source) {
        try data.update_source_breakpoints_line(origin.source, breakpoints);
    }

    for (breakpoints) |bp| {
        if (origin == .event) {
            try data.update_breakpoint(bp);
        } else {
            try data.breakpoints.ensureUnusedCapacity(data.allocator, 1);
            const cloned = try utils.mem_object(data.allocator, Breakpoint{
                .origin = origin,
                .breakpoint = bp,
            });
            data.breakpoints.appendAssumeCapacity(cloned);
        }
    }
}

pub fn clear_breakpoints(data: *SessionData, origin: BreakpointOrigin) void {
    var i: usize = 0;
    while (i < data.breakpoints.items.len) {
        const entry = data.breakpoints.items[i];
        if (std.meta.activeTag(entry.value.origin) == std.meta.activeTag(origin)) {
            var value = data.breakpoints.orderedRemove(i);
            value.deinit();
        } else {
            i += 1;
        }
    }
}

pub fn remove_breakpoint(data: *SessionData, id: ?i32) void {
    const index = data.breakpoint_index(id) orelse return;
    var value = data.breakpoints.orderedRemove(index);
    value.deinit();
}

fn update_breakpoint(data: *SessionData, breakpoint: protocol.Breakpoint) !void {
    const id = breakpoint.id orelse return error.NoBreakpointIDGiven;
    const index = data.breakpoint_index(id) orelse return error.BreakpointDoesNotExist;

    var old = data.breakpoints.items[index];
    const cloned = try utils.mem_object(data.allocator, Breakpoint{
        .origin = old.value.origin,
        .breakpoint = breakpoint,
    });

    old.deinit();
    data.breakpoints.items[index] = cloned;
}

pub fn add_source_breakpoint(data: *SessionData, not_owned_source_id: SourceID, breakpoint: protocol.SourceBreakpoint) !void {
    try data.source_breakpoints.ensureUnusedCapacity(data.allocator, 1);

    const source_id = try data.intern_source_id(not_owned_source_id);
    const gop = data.source_breakpoints.getOrPutAssumeCapacity(source_id);

    if (!gop.found_existing) {
        gop.value_ptr.* = .empty;
    }

    if (!gop.value_ptr.contains(breakpoint.line)) {
        const cloned = try data.clone_anytype(breakpoint);
        try gop.value_ptr.put(data.allocator, breakpoint.line, cloned);
    }
}

pub fn remove_source_breakpoint(data: *SessionData, source_id: SourceID, line: i32) void {
    var breakpoints = data.source_breakpoints.getPtr(source_id) orelse return;
    _ = breakpoints.swapRemove(line);
}

fn update_source_breakpoints_line(data: *SessionData, source_id: SourceID, new_breakpoints: []const protocol.Breakpoint) !void {
    const breakpoints = data.source_breakpoints.getPtr(source_id) orelse return;

    // https://microsoft.github.io/debug-adapter-protocol/specification#Requests_SetBreakpoints
    if (new_breakpoints.len != breakpoints.count()) return error.InvalidBreakpointResponse;
    for (breakpoints.keys(), breakpoints.values(), new_breakpoints) |*key, *a, b| {
        key.* = b.line orelse continue;
        a.line = b.line orelse continue;
    }

    breakpoints.reIndex(data.allocator) catch |err| switch (err) {
        error.OutOfMemory => unreachable,
    };
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

fn breakpoint_index(data: SessionData, maybe_id: ?i32) ?usize {
    const id = maybe_id orelse return null;
    for (data.breakpoints.items, 0..) |item, i| {
        if (item.value.breakpoint.id == id) {
            return i;
        }
    }

    return null;
}

fn clone_anytype(data: *SessionData, value: anytype) error{OutOfMemory}!@TypeOf(value) {
    const Cloner = struct {
        const Cloner = @This();
        data: *SessionData,
        allocator: mem.Allocator,
        pub fn clone_string(cloner: Cloner, string: []const u8) ![]const u8 {
            return try cloner.data.intern_string(string);
        }
    };

    const cloner = Cloner{
        .data = data,
        .allocator = data.arena.allocator(),
    };
    return try utils.clone_anytype(cloner, value);
}

fn intern_string(data: *SessionData, string: []const u8) ![]const u8 {
    return try data.string_storage.get_and_put(data.allocator, string);
}

fn intern_source_id(data: *SessionData, source_id: SourceID) !SourceID {
    return switch (source_id) {
        .path => |path| .{ .path = try data.string_storage.get_and_put(data.allocator, path) },
        .reference => |ref| .{ .reference = ref },
    };
}
